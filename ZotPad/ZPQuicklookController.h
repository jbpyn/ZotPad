//
//  ZPThumbnailButtonTarget.h
//  ZotPad
//
//  Created by Rönkkö Mikko on 1/2/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "ZPZoteroItem.h"
#import "ZPZoteroAttachment.h"

#import <Foundation/Foundation.h>

//For showing file thumbnails
#import <QuickLook/QuickLook.h>

@interface ZPQuicklookController : NSObject <QLPreviewControllerDataSource>{
    NSMutableArray* _fileURLs;
    UIViewController* _source;
}

+(ZPQuicklookController*) instance;
-(void) openItemInQuickLook:(ZPZoteroItem*)item attachmentIndex:(NSInteger)index sourceView:(UIViewController*)view;

@end