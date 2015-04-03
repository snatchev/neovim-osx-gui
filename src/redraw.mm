#include <cassert>
#include <iostream>
#include <string>
#include <vector>

#include <msgpack.hpp>

#include "redraw-hash.gen.h"

#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CoreFoundation.h>
#import "view.h"
#import "graphics.h"

static const bool debug = true;

#define RGBA(r,g,b,a) [NSColor colorWithCalibratedRed:r/255.f green:g/255.f blue:b/255.f alpha:a/255.f]
#define NSColorFromRGB(rgbValue) [NSColor colorWithCalibratedRed:((float)((rgbValue & 0xFF0000) >> 16))/255.0 green:((float)((rgbValue & 0xFF00) >> 8))/255.0 blue:((float)(rgbValue & 0xFF))/255.0 alpha:1.0]

using msgpack::object;

@implementation VimView (Redraw)

- (int) bufferLocation
{
  return(mCursorPos.y * mXCells + mCursorPos.x);
}

- (void) redraw:(const msgpack::object &)update_o
{
    bool didAnything = false;

    [mTextAttrs setValue:mFont forKey:NSFontAttributeName];
    [self.textStorage beginEditing];

    try
    {
        assert([NSThread isMainThread]);

        if (debug) std::cout << "-- " << update_o.via.array.size << "\n";

        for(int i=0; i<update_o.via.array.size; i++) {


            const object &item_o = update_o.via.array.ptr[i];

            if (debug) std::cout << item_o << "\n";

            assert(item_o.via.array.size >= 1);

            const object &action_o = item_o.via.array.ptr[0];

            const RedrawAction *action = RedrawHash::in_word_set(
                action_o.via.str.ptr,
                action_o.via.str.size
            );

            if (!action) {
                std::cout << "?? " << item_o << "\n";
                continue;
            }

            didAnything = true;

            [self doAction:action->code withItem:item_o];
        }
    }
    catch(std::exception &e) {
        assert(0);
        std::exit(-1);
    }

    if (didAnything) {
        if (debug) std::cout << "--\n";
        [self setNeedsDisplay:YES];
    }
    else
        if (debug) std::cout << "..\n";


    [self.textStorage endEditing];
}

- (void) doAction:(RedrawCode::Enum)code withItem:(const object &)item_o
{
    int item_sz = item_o.via.array.size;
    object *arglists = item_o.via.array.ptr + 1;
    int narglists = item_sz - 1;

    if (code == RedrawCode::put) {
        static std::string run;
        run.clear();

        for (int i=1; i<item_sz; i++) {
            const object &arglist = item_o.via.array.ptr[i];

            assert(arglist.via.array.size == 1);
            const object &char_o = arglist.via.array.ptr[0];
            run += char_o.as<std::string>();
        }

        NSString *nsrun = [NSString stringWithUTF8String:run.c_str()];
        int size = [nsrun length];
        [self.textStorage replaceCharactersInRange: NSMakeRange([self bufferLocation], size)
                                   withAttributedString: [[NSAttributedString alloc] initWithString: nsrun attributes:mTextAttrs]];

        mCursorPos.x += size;
    }
    else for (int i=0; i<narglists; i++) {
        const object &arglist = arglists[i];
        [self doAction:code withArgc:arglist.via.array.size argv:arglist.via.array.ptr];
    }

    if (mCursorOn)
        mCursorDisplayPos = mCursorPos;
}

- (void) doAction:(RedrawCode::Enum)code withArgc:(int)argc argv:(const object *)argv
{
    NSRect viewFrame = [self frame];

    switch(code)
    {
        case RedrawCode::update_fg:
        case RedrawCode::update_bg:
        {
            NSColor **dest = (code == RedrawCode::update_fg) ?
                &mForegroundColor : &mBackgroundColor;

            int rgb = argv[0].convert();

            [*dest release];

            if (rgb == -1)
                *dest = (code == RedrawCode::update_fg ? [NSColor blackColor] : [NSColor whiteColor]);
            else
                *dest = NSColorFromRGB(rgb);

            [*dest retain];
            break;
        }

        case RedrawCode::cursor_on:
        {
            mCursorOn = true;
            mCursorDisplayPos = mCursorPos;
            break;
        }

        case RedrawCode::cursor_off:
        {
            mCursorOn = false;
            break;
        }

        case RedrawCode::cursor_goto:
        {
            mCursorPos.y = argv[0].convert();
            mCursorPos.x = argv[1].convert();

            if (mCursorOn)
                mCursorDisplayPos = mCursorPos;

            break;
        }

        case RedrawCode::clear:
        {
            mCursorPos.x = 0;
            mCursorPos.y = 0;

            if (mCursorOn)
                mCursorDisplayPos = mCursorPos;

            [mBackgroundColor set];
            NSRectFill(viewFrame);
            break;
        }

        case RedrawCode::eol_clear:
        {
            [self.textStorage replaceCharactersInRange: NSMakeRange([self bufferLocation], 1) withString:@"\n"];

            NSRect rect;
            rect.origin.x = mCursorPos.x * mCharSize.width;
            rect.origin.y = viewFrame.size.height - (mCursorPos.y + 1) * mCharSize.height;
            rect.size.width = viewFrame.size.width - mCursorPos.x;
            rect.size.height = mCharSize.height;
            [mBackgroundColor set];
            NSRectFill( rect ) ;
            break;
        }

        case RedrawCode::highlight_set:
        {
            std::map<std::string, msgpack::object> j_m = argv[0].convert();

            NSColor *color;
            try {
                unsigned fg = j_m.at("foreground").convert();
                color = NSColorFromRGB(fg);
            }
            catch(...) { color = mForegroundColor; }
            [mTextAttrs setValue:color forKey:NSForegroundColorAttributeName];

            try {
                unsigned bg = j_m.at("background").convert();
                color = NSColorFromRGB(bg);
            }
            catch(...) { color = mBackgroundColor; }

            [mTextAttrs setValue:color forKey:NSBackgroundColorAttributeName];

            break;
        }

        case RedrawCode::set_scroll_region:
        {
            int y = mCellScrollRect.origin.y = argv[0].convert();
            int x = mCellScrollRect.origin.x = argv[2].convert();
            mCellScrollRect.size.height = argv[1].as<int>() - y + 1;
            mCellScrollRect.size.width = argv[3].as<int>() - x + 1;
            break;
        }

        /* Scroll by drawing our canvas context into itself,
           offset and clipped. */
        case RedrawCode::scroll:
        {
            /*
            int amt = argv[0].convert();

            NSRect destInPoints = [self viewRectFromCellRect:mCellScrollRect];

            NSRect totalRect = {CGPointZero, sizeInPoints};

            totalRect.origin.y += amt * mCharSize.height;

            CGContextSaveGState(mCanvasContext);
            CGContextClipToRect(mCanvasContext, destInPoints);
            drawBitmapContext(mCanvasContext, mCanvasContext, totalRect);
            CGContextRestoreGState(mCanvasContext);

            [mBackgroundColor set];
            if (amt > 0) {
                destInPoints.size.height = amt * mCharSize.height;
                NSRectFill(destInPoints);
            }
            if (amt < 0) {
                int ny = (-amt) * mCharSize.height;
                destInPoints.origin.y += destInPoints.size.height - ny;
                destInPoints.size.height = ny;
                NSRectFill(destInPoints);
            }

            break;
            */
        }

        case RedrawCode::resize:
        {
            mXCells = argv[0].convert();
            mYCells = argv[1].convert();
            mCellScrollRect = CGRectMake(0, 0, mXCells, mYCells);
            break;
        }

        case RedrawCode::normal_mode:
        {
            mInsertMode = false;
            break;
        }

        case RedrawCode::insert_mode:
        {
            mInsertMode = true;
            break;
        }

        case RedrawCode::bell:
        {
            NSBeep();
            break;
        }

        // Ignore these for now
        case RedrawCode::mouse_on:
        case RedrawCode::mouse_off:
        case RedrawCode::busy_start:
        case RedrawCode::busy_stop:
            break;

        default:
        {
            assert(0);
            break;
        }
    }
}

@end
