#include <string>
#include "vim.h"

#import <Cocoa/Cocoa.h>

#import "view.h"
#import "input.h"
#import "graphics.h"

@implementation VimView

- (BOOL)acceptsFirstResponder
{
    return YES;
};

- (id)initWithFrame:(NSRect)frame vim:(Vim *)vim
{
    if (self = [super initWithFrame:frame]) {
        mVim = vim;

        CGSize sizeInPoints = CGSizeMake(1920, 1080);
        CGSize sizeInPixels = [self convertSizeToBacking:sizeInPoints];

        mBackgroundColor = [[NSColor whiteColor] retain];
        mForegroundColor = [[NSColor blackColor] retain];
        mWaitAck = 0;

        /* Load font from saved settings */
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        mFont = [NSFont fontWithName:[defaults stringForKey:@"fontName"]
                                size:[defaults floatForKey:@"fontSize"]];
        [mFont retain];

        mTextAttrs = [[NSMutableDictionary dictionaryWithObjectsAndKeys:
            mForegroundColor, NSForegroundColorAttributeName,
            mBackgroundColor, NSBackgroundColorAttributeName,
            mFont, NSFontAttributeName,
            nil
        ] retain];

        [[NSFontManager sharedFontManager] setSelectedFont:mFont isMultiple:NO];
        [[NSFontManager sharedFontManager] setDelegate:self];

        [self updateCharSize];

        mCursorPos = mCursorDisplayPos = CGPointZero;
        mCursorOn = true;

        self.editable = NO;
    }

    return self;
}

- (id)initWithCellSize:(CGSize)cellSize vim:(Vim *)vim
{
    NSRect frame = CGRectMake(0, 0, 800, 600);

    if (self = [self initWithFrame:frame vim:vim]) {
        frame.size = [self viewSizeFromCellSize:cellSize];
        [self setFrame:frame];
        int length = cellSize.width * cellSize.height;
        [self.textStorage.mutableString setString:[[NSString string] stringByPaddingToLength:length withString:@" " startingAtIndex:0]];
        [self.textStorage setAttributes:mTextAttrs range:NSMakeRange(0,length)];
        self.textStorage.delegate = self;
    }
    return self;
}

/* Ask the font panel not to show colors, effects, etc. It'll still show color
   options in the cogwheel menu anyway because apple. */
- (NSUInteger)validModesForFontPanel:(NSFontPanel *)fontPanel
{
    return NSFontPanelFaceModeMask |
           NSFontPanelSizeModeMask |
           NSFontPanelCollectionModeMask;
}

- (void)updateCharSize
{
    mCharSize = [@" " sizeWithAttributes:mTextAttrs];
}

- (void)changeFont:(id)sender
{
    mFont = [sender convertFont:mFont];

    //update user defaults with new font
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:mFont.fontName forKey:@"fontName"];
    [defaults setFloat:mFont.pointSize forKey:@"fontSize"];

    [mTextAttrs setValue:mFont forKey:NSFontAttributeName];
    [self updateCharSize];

    NSWindow *win = [self window];
    NSRect frame = [win frame];
    frame = [win contentRectForFrameRect:frame];
    CGSize cellSize = {(float)mXCells, (float)mYCells};
    frame.size = [self viewSizeFromCellSize:cellSize];
    frame = [win frameRectForContentRect:frame];
    [win setFrame:frame display:NO];

    mVim->vim_command("redraw!");
}

- (void)cutText
{
    if (!mInsertMode) {
        mVim->vim_command("normal! \"+d");
    }
}

- (void)copyText
{
    if (!mInsertMode) {
        mVim->vim_command("normal! \"+y");
    }
}

- (void)pasteText
{
    if (mInsertMode) {
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        NSString* string = [pasteboard stringForType:NSPasteboardTypeString];
        string = [string stringByReplacingOccurrencesOfString:@"<"
                                                   withString:@"<lt>"];
        [self vimInput:[string UTF8String]];
    }
    else {
        mVim->vim_command("normal! \"+p");
    }
}

- (void)openFile:(NSString *)filename
{
    filename = [filename stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    filename = [filename stringByReplacingOccurrencesOfString:@" " withString:@"\\ "];
    filename = [filename stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    filename = [@"e " stringByAppendingString:filename];
    mVim->vim_command([filename UTF8String]);
}

/*  When drawing, it's important that our canvas image is in the same color
    space as the destination, otherwise drawing will be very slow. */

/*
- (void)viewDidMoveToWindow
{
    NSColorSpace *nsColorSpace =
        [[[NSColorSpace alloc] initWithCGColorSpace:mColorSpace] autorelease];

    [[self window] setColorSpace:nsColorSpace];
}
*/


/* -- Resizing -- */

- (void)viewDidEndLiveResize
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger: mXCells forKey:@"width"];
    [defaults setInteger: mYCells forKey:@"height"];
    [self display];
}

- (void)requestResize:(CGSize)cellSize
{
    int xCells = (int)cellSize.width;
    int yCells = (int)cellSize.height;

    if (xCells == mXCells && yCells == mYCells)
        return;

    if (mVim)
        mVim->ui_try_resize((int)cellSize.width, (int)cellSize.height);
}


/* -- Coordinate conversions -- */

- (NSRect)viewRectFromCellRect:(NSRect)cellRect
{
    CGFloat sy1 = cellRect.origin.y + cellRect.size.height;

    NSRect viewRect;
    viewRect.origin.x = cellRect.origin.x * mCharSize.width;
    viewRect.origin.y = [self frame].size.height - sy1 * mCharSize.height;
    viewRect.size = [self viewSizeFromCellSize:cellRect.size];
    return viewRect;
}

- (CGSize)viewSizeFromCellSize:(CGSize)cellSize
{
    return CGSizeMake(
        cellSize.width * mCharSize.width,
        cellSize.height * mCharSize.height
    );
}

- (CGSize)cellSizeInsideViewSize:(CGSize)viewSize
{
    CGSize cellSize;
    cellSize.width = int(viewSize.width / mCharSize.width);
    cellSize.height = int(viewSize.height / mCharSize.height);
    return cellSize;
}

- (NSPoint)cellContaining:(NSPoint)viewPoint
{
    CGFloat y = [self frame].size.height - viewPoint.y;
    NSPoint cellPoint;
    cellPoint.x = int(viewPoint.x / mCharSize.width);
    cellPoint.y = int(y / mCharSize.height);
    return cellPoint;
}

@end
