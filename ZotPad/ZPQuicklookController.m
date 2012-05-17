//
//  ZPThumbnailButtonTarget.m
//  ZotPad
//
//  Created by Rönkkö Mikko on 1/2/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "ZPCore.h"

#import "ZPQuicklookController.h"
#import "ZPZoteroItem.h"
#import "ZPZoteroAttachment.h"
#import "ZPDatabase.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <QuartzCore/QuartzCore.h>
#import "ZPItemDetailViewController.h"
#import "ZPServerConnection.h"

#import "ZPPreferences.h"
#import "ZPDataLayer.h"
#import "ZPLogger.h"

//Unzipping and base64 decoding
#import "ZipArchive.h"
#import "QSStrings.h"



@interface ZPQuicklookController(){
    ZPZoteroAttachment* _activeAttachment;
    QLPreviewController* _quicklook;
}
- (void) _displayQuicklook;
- (void) _addAttachmentToQuicklook:(ZPZoteroAttachment *)attachment;

@end



@implementation ZPQuicklookController


static ZPQuicklookController* _instance;

+(ZPQuicklookController*) instance{
    if(_instance == NULL){
        _instance = [[ZPQuicklookController alloc] init];
    }
    return _instance;
}

-(id) init{
    self = [super init];
    _quicklook = [[QLPreviewController alloc] init];
    [_quicklook setDataSource:self];
    [_quicklook setDelegate:self];
    
    _fileURLs = [[NSMutableArray alloc] init];
    return self;
}

-(void) openItemInQuickLook:(ZPZoteroAttachment*)attachment sourceView:(UIView*)view{
    
    _source = view;
    // Mark this file as recently viewed. This will be done also in the case
    // that the file cannot be downloaded because the fact that user tapped an
    // item is still relevant information for the cache controller
 
    
    [[ZPDatabase instance] updateViewedTimestamp:attachment];
    if([attachment.linkMode intValue] == LINK_MODE_LINKED_URL){
        NSString* urlString = [[(ZPZoteroItem*)[ZPZoteroItem dataObjectWithKey:attachment.parentItemKey] fields] objectForKey:@"url"];

        //Links will be opened with safari.
        NSURL* url = [NSURL URLWithString: urlString];
        [[UIApplication sharedApplication] openURL:url];
    }
    
    //This should never be shown, but it is implemented just to be suser 
    
    else if(! attachment.fileExists){
        UIAlertView *message = [[UIAlertView alloc] initWithTitle:@"File not found"
                                                          message:[NSString stringWithFormat:@"The file %@ was not found on ZotPad.",attachment.filename]
                                                         delegate:nil
                                                cancelButtonTitle:@"Cancel"
                                                otherButtonTitles:nil];
        
        [message show];
    }
    else {
        [self _addAttachmentToQuicklook:attachment];
        [self _displayQuicklook];
    }
}


- (void) _addAttachmentToQuicklook:(ZPZoteroAttachment *)attachment{
    
    // Imported URLs need to be unzipped
    if([attachment.linkMode intValue] == LINK_MODE_IMPORTED_URL && [attachment.contentType isEqualToString:@"text/html"]){
        
        NSString* tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:attachment.key];
        
        if([[NSFileManager defaultManager] fileExistsAtPath:tempDir]){
            [[NSFileManager defaultManager] removeItemAtPath:tempDir error:NULL];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir 
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        ZipArchive* zipArchive = [[ZipArchive alloc] init];
        [zipArchive UnzipOpenFile:attachment.fileSystemPath];
        [zipArchive UnzipFileTo:tempDir overWrite:YES];
        [zipArchive UnzipCloseFile];

        //List the unzipped files and decode them
        
        NSArray* files = [[NSFileManager defaultManager]contentsOfDirectoryAtPath:tempDir error:NULL];
        
        for (NSString* file in files){
            NSLog(@"Unzipped file %@ into temp dir %@",file,tempDir);
            // The filenames end with %ZB64, which needs to be removed
            NSString* toBeDecoded = [file substringToIndex:[file length] - 5];
            NSData* decodedData = [QSStrings decodeBase64WithString:toBeDecoded] ;
            NSString* decodedFilename = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            NSLog(@"Decoded %@ as %@",toBeDecoded, decodedFilename);
        
            [[NSFileManager defaultManager] moveItemAtPath:[tempDir stringByAppendingPathComponent:file] toPath:[tempDir stringByAppendingPathComponent:decodedFilename] error:NULL];

        }
        
        [_fileURLs addObject:[NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:attachment.filename]]];
    }
    else{
        [_fileURLs addObject:[NSURL fileURLWithPath:attachment.fileSystemPath]];
    }
}


- (void) _displayQuicklook{
    [_quicklook reloadData];
    [_quicklook setCurrentPreviewItemIndex:[_fileURLs count]-1];
    UIViewController* root = [UIApplication sharedApplication].delegate.window.rootViewController;        
    [root presentModalViewController:_quicklook animated:YES];
    
}


#pragma mark - Quick Look data source methods

- (NSInteger) numberOfPreviewItemsInPreviewController: (QLPreviewController *) controller 
{
    return [_fileURLs count];
}


- (id <QLPreviewItem>) previewController: (QLPreviewController *) controller previewItemAtIndex: (NSInteger) index{
    return [_fileURLs objectAtIndex:index];
}

#pragma mark - Quick Look delegate methods

//Needed to provide zoom effect

- (CGRect)previewController:(QLPreviewController *)controller frameForPreviewItem:(id <QLPreviewItem>)item inSourceView:(UIView **)view{
    *view = _source;
    CGRect frame = _source.frame;
    return frame; 
} 


- (UIImage *)previewController:(QLPreviewController *)controller transitionImageForPreviewItem:(id <QLPreviewItem>)item contentRect:(CGRect *)contentRect{
    if([_source isKindOfClass:[UIImageView class]]) return [(UIImageView*) _source image];
    else{
        UIImageView* imageView = (UIImageView*) [_source viewWithTag:1];
        return imageView.image;
    }
}

// Should URL be opened
- (BOOL)previewController:(QLPreviewController *)controller shouldOpenURL:(NSURL *)url forPreviewItem:(id <QLPreviewItem>)item{
    return YES;
}

@end
