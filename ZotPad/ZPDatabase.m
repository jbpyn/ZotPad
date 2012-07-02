//
//  ZPDatabase.m
//  ZotPad
//
//  This class contains all database operations.
//
//  Created by Rönkkö Mikko on 12/16/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//


#include <sys/xattr.h>

#import "ZPCore.h"


#import "ZPDatabase.h"

//Data objects
#import "ZPZoteroLibrary.h"
#import "ZPZoteroCollection.h"
#import "ZPZoteroItem.h"
#import "ZPZoteroNote.h"
#import "ZPZoteroAttachment.h"

//DB library
#import "../FMDB/src/FMDatabase.h"
#import "../FMDB/src/FMResultSet.h"

#import "ZPPreferences.h"



@interface  ZPDatabase (){
    NSMutableDictionary* dbFieldsByTables;
    NSMutableDictionary* dbPrimaryKeysByTables;
}
- (NSDictionary*) fieldsForItem:(ZPZoteroItem*)item;
- (NSArray*) creatorsForItem:(ZPZoteroItem*)item;

- (void) insertObjects:(NSArray*) objects intoTable:(NSString*) table;
- (void) updateObjects:(NSArray*) objects intoTable:(NSString*) table;
- (NSArray*) writeObjects:(NSArray*) objects intoTable:(NSString*) table checkTimestamp:(BOOL) checkTimestamp;

- (NSArray*) dbFieldNamesForTable:(NSString*) table;
- (NSArray*) dbPrimaryKeyNamesForTable:(NSString*) table;
- (NSArray*) dbFieldValuesForObject:(NSObject*) object fieldsNames:(NSArray*)fieldNames;

@end

@implementation ZPDatabase

static ZPDatabase* _instance = nil;

-(id)init
{
    self = [super init];
    
    _instance = self;

    dbFieldsByTables = [NSMutableDictionary dictionary];
    dbPrimaryKeysByTables = [NSMutableDictionary dictionary];

	NSString *dbPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"zotpad.sqlite"];
   
    // Uncomment to always reset database
    // [self resetDatabase];
    
    if(! [[NSFileManager defaultManager] fileExistsAtPath:dbPath]) [self resetDatabase];
    else{
        _database = [FMDatabase databaseWithPath:dbPath];
        [_database open];
    }

    [_database setTraceExecution:FALSE];
    [_database setLogsErrors:TRUE];

	return self;
}

/*
 
 Singleton accessor. 
 
 */

+(ZPDatabase*) instance {
    @synchronized(self){
        if(_instance == NULL){
            _instance = [[ZPDatabase alloc] init];
        }
        return _instance;
    }
}

/*
 
 Deletes and re-creates the database

 */

-(void) resetDatabase{
    @synchronized(self){
        
        NSError* error;
        
        NSString *dbPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"zotpad.sqlite"];
        
        if([[NSFileManager defaultManager] fileExistsAtPath:dbPath]){
            [[NSFileManager defaultManager] removeItemAtPath: dbPath error:&error];   
        }
        
        _database = [FMDatabase databaseWithPath:dbPath];
        
        [_database open];  
        //Prevent backing up of DB
        const char* filePath = [dbPath fileSystemRepresentation];
        const char* attrName = "com.apple.MobileBackup";
        u_int8_t attrValue = 1;
        setxattr(filePath, attrName, &attrValue, sizeof(attrValue), 0, 0);
        
        //Changing these two will affect how much info is printed in log
        [_database setTraceExecution:FALSE];
        [_database setLogsErrors:TRUE];
        
        //Read the database structure from file and create the database
        
        NSStringEncoding encoding;
        
        NSString *sqlFile = [NSString stringWithContentsOfFile:[[NSBundle mainBundle]
                                                                pathForResource:@"database"
                                                                ofType:@"sql"] usedEncoding:&encoding error:&error];
        
        NSArray *sqlStatements = [sqlFile componentsSeparatedByString:@";"];
        
        NSEnumerator *e = [sqlStatements objectEnumerator];
        id sqlString;
        
        while (sqlString = [e nextObject]) {
            if(! [[sqlString stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@""]){
                if(![_database executeUpdate:sqlString]){
                    [NSException raise:@"Database error" format:@"Error executing query %@",sqlString];   
                }
            }
        }
        
    }

}

#pragma mark -
#pragma mark Private methods for writing objects and relationships to DB


/*
 
 Does a batch insert into a table. Objects can be either dictionaries or Zotero data objects
 
 Note: All multiple inserts should go through this method
 
 */

- (void) insertObjects:(NSArray*) objects intoTable:(NSString*) table {

    NSArray* dbFieldNames = [self dbFieldNamesForTable:table];
    NSString* unionSelectSQL = [@" UNION SELECT " stringByPaddingToLength:12+[dbFieldNames count]*3 withString:@"?, " startingAtIndex:0];

    // The maximum rows in union select is 500. (http://www.sqlite.org/limits.html)
    // This methods splits the inserts into batches of 500
    
    NSMutableArray* objectsRemaining = [NSMutableArray arrayWithArray:objects];
    
    NSString* insertSQLBase = [NSMutableString stringWithFormat:@"INSERT INTO %@ (%@) SELECT ? AS %@",
                               table,
                               [dbFieldNames componentsJoinedByString:@", "],
                               [dbFieldNames componentsJoinedByString:@", ? AS "]];
    
    while([objectsRemaining count]>0){
        
        NSMutableArray* objectBatch = [NSMutableArray array];
        
        NSInteger counter =0;
        NSObject* object = [objectsRemaining lastObject];
        while(counter  < 500 && object != NULL){
            [objectBatch addObject:object];
            [objectsRemaining removeLastObject];
            counter++;
            object = [objectsRemaining lastObject];
        }
        
        NSMutableString* insertSQL = NULL;

        NSMutableArray* insertArguments = [NSMutableArray array];
        
        for (object in objectBatch){
            if(insertSQL == NULL){
                insertSQL = [NSMutableString stringWithString: insertSQLBase];
            }
            else [insertSQL appendString:unionSelectSQL];
            
            [insertArguments addObjectsFromArray:[self dbFieldValuesForObject:object fieldsNames:dbFieldNames]];
        }
            
            
        @synchronized(self){
            if(![_database executeUpdate:insertSQL withArgumentsInArray:insertArguments]){

                //Diagnose the error by running the queries one at a time

                for (object in objectBatch){
                    NSArray* arguments = [self dbFieldValuesForObject:object fieldsNames:dbFieldNames];
                    if(![_database executeUpdate:insertSQLBase withArgumentsInArray:arguments]){
                        [NSException raise:@"Database error" format:@"Error executing query %@ with arguments %@",insertSQLBase,arguments];   
                    }

                }
                //Finally raise an exception for the whole query if it failed
                [NSException raise:@"Database error" format:@"Error executing query %@ with arguments %@",insertSQL,insertArguments];
            }

        }
    }
    
}

/*
 
 Does a batch update into a table. Objects can be either dictionaries or Zotero data objects
 
 //TODO: Consider doing this with multirow updates instead, if possible.
 
*/

- (void) updateObjects:(NSArray*) objects intoTable:(NSString*) table {

    NSMutableArray* dataFieldNames = [NSMutableArray arrayWithArray:[self dbFieldNamesForTable:table]];
    NSArray* primaryKeyFieldNames = [self dbPrimaryKeyNamesForTable:table];
    
    if([dataFieldNames count]> [primaryKeyFieldNames count]){
        [dataFieldNames removeObjectsInArray:primaryKeyFieldNames];
        
        NSString* updateSQL = [NSString stringWithFormat:@"UPDATE %@ SET %@ = ? WHERE %@ = ?",
                               table,
                               [dataFieldNames componentsJoinedByString:@" = ?, "],
                               [primaryKeyFieldNames componentsJoinedByString:@" = ? AND"]];
        
        NSArray* allFields = [dataFieldNames arrayByAddingObjectsFromArray:primaryKeyFieldNames];
        
        for (NSObject* object in objects){
            @synchronized(self){
                NSArray* args = [self dbFieldValuesForObject:object fieldsNames:allFields];
                if(![_database executeUpdate:updateSQL withArgumentsInArray:args])
                    [NSException raise:@"Database error" format:@"Error executing query %@ with arguments %@",updateSQL,args];
 
            }
        }
    }
}

/*

 Writes (inserts or updates) the array of objects into database. Optionally checks timestamp and only writes objects where timestamps are different in database.

 */

- (NSArray*) writeObjects:(NSArray*) objects intoTable:(NSString*) table checkTimestamp:(BOOL) checkTimestamp{
    
    if([objects count] == 0 ) return objects;

    NSArray* primaryKeyFieldNames = [self dbPrimaryKeyNamesForTable:table];

    if([primaryKeyFieldNames count] > 1 && checkTimestamp){
        [NSException raise:@"Unsupported" format:@"Checkign timestamp is not supported for writing opbjects with multicolumn primary keys"];
    }

    //Because it is possible that the same item is received multiple times, it is important to use synchronized for almost the entire function to avoid inserting the same object twice
//    @synchronized(self){
        
        NSMutableArray* insertObjects = [NSMutableArray array];
        NSMutableArray* updateObjects = [NSMutableArray array];
        
        //Retrieve keys and timestamps from the DB
        if([primaryKeyFieldNames count]==1){
            NSMutableArray* keys = [NSMutableArray array];
            for(NSObject* object in objects){
                [keys addObject:[[self dbFieldValuesForObject:object fieldsNames:primaryKeyFieldNames] objectAtIndex:0]];
            }
            
            BOOL keysAreString = [[keys objectAtIndex:0] isKindOfClass:[NSString class]];
            
            if(checkTimestamp){
                //Check if the keys are string
                NSString* selectSQL;
                if(keysAreString){
                    selectSQL= [NSString stringWithFormat:@"SELECT %@, cacheTimestamp FROM %@ WHERE %@ IN ('%@')",
                                [primaryKeyFieldNames objectAtIndex:0],
                                table,
                                [primaryKeyFieldNames objectAtIndex:0],
                                [keys componentsJoinedByString:@"', '"]];
                }
                else{
                    selectSQL= [NSString stringWithFormat:@"SELECT %@, cacheTimestamp FROM %@ WHERE %@ IN (%@)",
                                [primaryKeyFieldNames objectAtIndex:0],
                                table,
                                [primaryKeyFieldNames objectAtIndex:0],
                                [keys componentsJoinedByString:@", "]];
                }
                
                
                NSMutableDictionary* timestamps = [NSMutableDictionary dictionary];
                
                //Retrieve timestamps
                @synchronized(self){
                    FMResultSet* resultSet = [_database executeQuery:selectSQL];
                    
                    while([resultSet next]){
                        [timestamps setObject:[resultSet stringForColumnIndex:1] forKey:[resultSet stringForColumnIndex:0]];
                    }
                    [resultSet close];
                }
                
                NSMutableArray* returnArray=[NSMutableArray array]; 
                
                
                NSArray* keyArrayFieldName = [NSArray
                                               arrayWithObject:[primaryKeyFieldNames objectAtIndex:0]];
                
                for (NSObject* object in objects){
                    
                    //Check the timestamp
                    NSString* timestamp = [timestamps objectForKey:[[self dbFieldValuesForObject:object fieldsNames:keyArrayFieldName] objectAtIndex:0]];
                    
                    //Insert if timestamp is not found
                    if(timestamp == NULL){
                        [insertObjects addObject:object];
                        [returnArray addObject:object];
                        
                    }
                    //Update if timestamps differ
                    else if(! [[[self dbFieldValuesForObject:object fieldsNames:[NSArray arrayWithObject: @"cacheTimestamp"]] objectAtIndex:0] isEqual: timestamp]){
                        [updateObjects addObject:object];
                        [returnArray addObject:object];
                    }
                }
                [self updateObjects:updateObjects intoTable:table];
                [self insertObjects:insertObjects intoTable:table];
                return returnArray;
            }
            //No checking of timestamp
            else{
                NSString* selectSQL;
                if(keysAreString){
                    selectSQL= [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ IN ('%@')",
                                [primaryKeyFieldNames objectAtIndex:0],
                                table,
                                [primaryKeyFieldNames objectAtIndex:0],
                                [keys componentsJoinedByString:@"', '"]];
                }
                else{
                    selectSQL= [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ IN (%@)",
                                [primaryKeyFieldNames objectAtIndex:0],
                                table,
                                [primaryKeyFieldNames objectAtIndex:0],
                                [keys componentsJoinedByString:@", "]];
                }
                
                
                NSMutableSet* keys = [NSMutableSet set];
                
                //Retrieve keys
                @synchronized(self){
                    FMResultSet* resultSet = [_database executeQuery:selectSQL];
                    
                    while([resultSet next]){
                        if(keysAreString) [keys addObject:[resultSet stringForColumnIndex:0]];
                        else [keys addObject:[NSNumber numberWithInt:[resultSet intForColumnIndex:0]]];
                    }
                    [resultSet close];
                }
                
                for (NSObject* object in objects){
                    
                    //Insert if key is not found
                    if( ! [keys containsObject:[[self dbFieldValuesForObject:object fieldsNames:primaryKeyFieldNames] objectAtIndex:0]]){
                        [insertObjects addObject:object];
                    }
                    else{
                        [updateObjects addObject:object];
                    }
                }
                [self updateObjects:updateObjects intoTable:table];
                [self insertObjects:insertObjects intoTable:table];
                
                return objects;
                
            }
        }
        //Multiple colums in primary key
        else{
            NSString* selectSQL= [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ = ?",
                                  [primaryKeyFieldNames objectAtIndex:0],
                                  table,
                                  [primaryKeyFieldNames componentsJoinedByString:@" = ? AND "]];
            
            
            //Check if things exist with these primary keys
            
            for(NSObject* object in objects){
                @synchronized(self){
                    FMResultSet* resultSet = [_database executeQuery:selectSQL withArgumentsInArray:[self dbFieldValuesForObject:object fieldsNames:primaryKeyFieldNames]];
                    
                    if([resultSet next]) [updateObjects addObject:object];
                    else [insertObjects addObject:object];
                    [resultSet close];
                }
            }
            [self updateObjects:updateObjects intoTable:table];
            [self insertObjects:insertObjects intoTable:table];
            return objects;
        }
//    }
}


- (NSArray*) dbFieldNamesForTable:(NSString*) table{
    NSArray* returnArray = [dbFieldsByTables objectForKey:table];
    if(returnArray == NULL){
        NSMutableArray* mutableReturnArray = [NSMutableArray array];
        @synchronized(self){
            FMResultSet* resultSet = [_database executeQuery:[NSString stringWithFormat:@"pragma table_info(%@)",table]];
            
            while([resultSet next]){
                [mutableReturnArray addObject:[resultSet stringForColumn:@"name"]];
            }
            [resultSet close];
        }
        [dbFieldsByTables setObject:mutableReturnArray forKey:table];
        returnArray = mutableReturnArray;
            
    }
    return returnArray;
}

- (NSArray*) dbPrimaryKeyNamesForTable:(NSString*) table{
    NSArray* returnArray = [dbPrimaryKeysByTables objectForKey:table];
    if(returnArray == NULL){
        NSMutableArray* mutableReturnArray = [NSMutableArray array];
        @synchronized(self){
            FMResultSet* resultSet = [_database executeQuery:[NSString stringWithFormat:@"pragma table_info(%@)",table]];
            
            while([resultSet next]){
                if([resultSet intForColumn:@"pk"]) [mutableReturnArray addObject:[resultSet stringForColumn:@"name"]];
            }
            [resultSet close];
        }
        [dbPrimaryKeysByTables setObject:mutableReturnArray forKey:table];
        returnArray = mutableReturnArray;
        
    }
    return returnArray;
    
}

- (NSArray*) dbFieldValuesForObject:(NSObject*) object fieldsNames:(NSArray*)fieldNames{
    NSMutableArray* returnArray = [NSMutableArray array];

    for(NSString* fieldName in fieldNames){
        if([object isKindOfClass:[NSDictionary class]]){
            NSObject* value = [(NSDictionary*) object objectForKey:fieldName];
            if(value!=NULL) [returnArray addObject:value];
            else [returnArray addObject:[NSNull null]];
        }
        else{
            SEL selector = NSSelectorFromString(fieldName);
            NSObject* value = [object performSelector:selector];
            if(value!=NULL) [returnArray addObject:value];
            else [returnArray addObject:[NSNull null]];
        }
    }
    return returnArray;
}


#pragma mark -
#pragma mark Library methods

/*
 
 Writes an array of ZPZoteroLibrary objects into the database
 
 */

-(void) writeLibraries:(NSArray*)libraries{
    [self writeObjects:libraries intoTable:@"libraries" checkTimestamp:FALSE];
    
}

- (void) setUpdatedTimestampForLibrary:(NSNumber*)libraryID toValue:(NSString*)updatedTimestamp{
    @synchronized(self){
        [_database executeUpdate:@"UPDATE libraries SET cacheTimestamp = ? WHERE libraryID = ?",updatedTimestamp,libraryID];
    }
}

/*
 
 Returns an array of ZPLibrary objects
 
 */

- (NSArray*) libraries{
    NSMutableArray* returnArray = [[NSMutableArray alloc] init];

    //Group libraries
    @synchronized(self){
        
        FMResultSet* resultSet = [_database executeQuery:@"SELECT *, (SELECT count(*) FROM collections WHERE libraryID=libraries.libraryID AND parentCollectionKey IS NULL) AS numChildren FROM libraries ORDER BY libraryID <> 1 ,LOWER(title)"];
        
        while([resultSet next]) {
            [returnArray addObject:[ZPZoteroLibrary dataObjectWithDictionary:[resultSet resultDict]]];
        }
        [resultSet close];
    }
	return returnArray;
}
/*
 
 Reads data for for a group library and updates the library object
 
 */
- (void) addAttributesToGroupLibrary:(ZPZoteroLibrary*) library{
    @synchronized(self){
        
        FMResultSet* resultSet = [_database executeQuery:@"SELECT *, (SELECT count(*) FROM collections WHERE libraryID=libraryID AND parentCollectionKey IS NULL) AS numChildren FROM libraries WHERE libraryID = ?  LIMIT 1",library.libraryID];
        
        if([resultSet next]){
            [library configureWithDictionary:[resultSet resultDict]];
        }
        [resultSet close];
        
    }
}



#pragma mark - 

#pragma mark Collection methods

/*
 
 Writes an array of ZPZoteroCollections belonging to a ZPZoteroLibrary to database
 
 */

-(void) writeCollections:(NSArray*)collections toLibrary:(ZPZoteroLibrary*)library{

    
    NSEnumerator* e = [collections objectEnumerator];
    NSMutableArray* keys = [NSMutableArray arrayWithCapacity:[collections count]];
    ZPZoteroCollection* collection;

    while(collection = [e nextObject]){
        [keys addObject:collection.key];
    }

    [self writeObjects:collections intoTable:@"collections" checkTimestamp:FALSE];
    
    // Delete collections that no longer exist

    @synchronized(self){
        [_database executeUpdate:[NSString stringWithFormat:@"DELETE FROM collections WHERE collectionKey NOT IN ('%@') and libraryID = ?",[keys componentsJoinedByString:@"', '"]],library.libraryID];
    }

    //Because parents come before children from the Zotero server, none of the collections in the in-memory cache will be flagged as having children.
    //An easy solution is to drop the cache - This is done so rarely that there is really no point in optimizing here
    
    [ZPZoteroCollection dropCache];
}

// These remove items from the collection
- (void) removeItemKeysNotInArray:(NSArray*)itemKeys fromCollection:(NSString*)collectionKey{

    if([itemKeys count] == 0) return;
    
    NSString* sql=[NSString stringWithFormat:@"DELETE FROM collectionItems WHERE collectionKey = ? AND itemKey NOT IN ('%@')",
                   [itemKeys componentsJoinedByString:@"', '"]];
    
    @synchronized(self){
        [_database executeUpdate:sql,collectionKey];
    }
    
}

- (void) setUpdatedTimestampForCollection:(NSString*)collectionKey toValue:(NSString*)updatedTimestamp{
    @synchronized(self){
        [_database executeUpdate:@"UPDATE collections SET cacheTimestamp = ? WHERE collectionKey = ?",updatedTimestamp,collectionKey];
    }
}

/*
 
 Returns an array of ZPZoteroCollections
 
 */

- (NSArray*) collectionsForLibrary : (NSNumber*)libraryID withParentCollection:(NSString*)collectionKey {
    
    NSMutableArray* returnArray = [[NSMutableArray alloc] init];
    
	@synchronized(self){
        
        FMResultSet* resultSet;
        if(collectionKey == NULL)
            resultSet= [_database executeQuery:@"SELECT *, (SELECT count(*) FROM collections WHERE parentCollectionKey = parent.collectionKey) AS numChildren FROM collections parent WHERE libraryID=? AND parentCollectionKey IS NULL ORDER BY LOWER(title)",libraryID];
        
        else
            resultSet= [_database executeQuery:@"SELECT *, (SELECT count(*) FROM collections WHERE parentCollectionKey = parent.collectionKey) AS numChildren FROM collections parent WHERE libraryID=? AND parentCollectionKey = ? ORDER BY LOWER(title)",libraryID,collectionKey];
        
        while([resultSet next]) {
            NSDictionary* dict = [resultSet resultDict];
            [returnArray addObject:[ZPZoteroCollection dataObjectWithDictionary:dict]];
            
        }
        [resultSet close];
        
	}
	return returnArray;
}

- (NSArray*) collectionsForLibrary : (NSNumber*)libraryID{
    NSMutableArray* returnArray = [[NSMutableArray alloc] init];
    
	@synchronized(self){
        
        FMResultSet* resultSet;
        resultSet= [_database executeQuery:@"SELECT *, (SELECT count(*) FROM collections WHERE parentCollectionKey = parent.collectionKey) AS numChildren FROM collections parent WHERE libraryID=?",libraryID];
           
        while([resultSet next]) {
            [returnArray addObject:[ZPZoteroCollection dataObjectWithDictionary:[resultSet resultDict]]];
            
        }
        [resultSet close];
        
	}
	return returnArray;
    
}


- (void) addAttributesToCollection:(ZPZoteroCollection*) collection{
    
    
	@synchronized(self){
        FMResultSet* resultSet = [_database executeQuery:@"SELECT *, collectionKey IN (SELECT DISTINCT parentCollectionKey FROM collections) AS hasChildren FROM collections WHERE collectionKey=? LIMIT 1",collection.key];
        
        
        if([resultSet next]){
            [collection configureWithDictionary:[resultSet resultDict]];
        }
        
        [resultSet close];
    }
}


#pragma mark - 
#pragma mark Item methods


/*
 
Deletes items, notes, and attachments based in array of keys from a library
 
 */

- (void) deleteItemKeysNotInArray:(NSArray*)itemKeys fromLibrary:(NSNumber*)libraryID{
    
    if([itemKeys count] == 0) return;
    
    @synchronized(self){

        [_database executeUpdate:[NSString stringWithFormat:@"DELETE FROM items WHERE libraryID = ? AND itemKey NOT IN ('%@')",
                                  [itemKeys componentsJoinedByString:@"', '"]],libraryID];
        
        [_database executeUpdate:[NSString stringWithFormat:@"DELETE FROM attachments WHERE itemKey NOT IN ('%@') AND parentItemKey IN (SELECT itemKey FROM items WHERE libraryID = ?)",
                                  [itemKeys componentsJoinedByString:@"', '"]],libraryID];

        [_database executeUpdate:[NSString stringWithFormat:@"DELETE FROM notes WHERE itemKey NOT IN ('%@') AND parentItemKey in (SELECT itemKey FROM items WHERE libraryID = ?)",
                                  [itemKeys componentsJoinedByString:@"', '"]],libraryID];


    }
}


/*
 
 Writes items to database. Returns the items that were added or modified.
 
 */

-(NSArray*) writeItems:(NSArray*)items {
    /*
     Check that all items have keys and item types defined
     */
    ZPZoteroItem* item;
    for(item in items){
        if(item.key==NULL){
            [NSException raise:@"Item key cannot be null" format:@""];
        }
        if(item.itemType==NULL){
            [NSException raise:@"Item type cannot be null" format:@""];
        }

    }
    return [self writeObjects:items intoTable:@"items" checkTimestamp:YES];
        
}

-(NSArray*) writeNotes:(NSArray*)notes{
    return [self writeObjects:notes intoTable:@"notes" checkTimestamp:YES];     
}

-(NSArray*) writeAttachments:(NSArray*)attachments{
    return [self writeObjects:attachments intoTable:@"attachments" checkTimestamp:YES];     
}


// Records a new collection membership

-(void) writeItems:(NSArray*)items toCollection:(NSString*)collectionKey{

    ZPZoteroItem* item;
    NSMutableArray* itemKeys = [NSMutableArray array];
    for(item in items){
        [itemKeys addObject:item.key];
    }
    [self writeItems:itemKeys toCollection:collectionKey];
}


-(void) addItemKeys:(NSArray*)keys toCollection:(NSString*)collectionKey{
    
    NSMutableArray* relationships= [NSMutableArray arrayWithCapacity:[keys count]];

    for(NSString* key in keys){
        [relationships addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:key, collectionKey, nil] forKeys:[NSArray arrayWithObjects:@"itemKey",@"collectionKey", nil]]];
    }

    [self writeObjects:relationships intoTable:@"collectionItems" checkTimestamp:NO];
}




- (NSDictionary*) attributesForItemWithKey:(NSString *)key{
    
    NSDictionary* results = NULL;
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery: @"SELECT * FROM items WHERE itemKey=? LIMIT 1",key];
        
        if ([resultSet next]) {
            results = [resultSet resultDict];
        }
        else results = [NSDictionary dictionaryWithObject:key forKey:@"itemKey"];

        [resultSet close];
        
        //TODO: Refactor
        NSString* itemType = [results objectForKey:@"itemType"];
        if(itemType == NULL || [itemType isEqualToString:@"attachment"]){                                       
            resultSet = [_database executeQuery: @"SELECT * FROM attachments WHERE itemKey=? LIMIT 1",key];

            if ([resultSet next]) {
                NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:results];
                [dict addEntriesFromDictionary: [resultSet resultDict]];
                results=dict;
            }
            
            [resultSet close];
        }
    }
    return results;
}


/*
 
 Writes or updates the creators for this field in the database
 
 
 */

-(void) writeItemsCreators:(NSArray*)items{
    
    if([items count]==0) return;
    
    NSMutableArray* creators= [NSMutableArray array];
    NSMutableString* deleteSQL;

    for(ZPZoteroItem* item in items){
        for(NSMutableDictionary* creator in item.creators){
            [creator setObject:item.key forKey:@"itemKey"];
            [creators addObject:creator];
        }
        if(deleteSQL == NULL){
            deleteSQL = [NSMutableString stringWithFormat:@"DELETE FROM creators WHERE (itemKey = '%@' AND authorOrder >= %i)",item.key,[item.creators count]];
        }
        else{
            [deleteSQL appendFormat:@" OR (itemKey = '%@' AND authorOrder >= %i)",item.key,[item.creators count]];
        }
    }
    
    [self writeObjects:creators intoTable:@"creators" checkTimestamp:FALSE];
 
    @synchronized(self){
        if(![_database executeUpdate:deleteSQL]){
            [NSException raise:@"Database error" format:@"Error executing query %@",deleteSQL];   
        }
    }
}


-(void) writeItemsFields:(NSArray*)items{

    if([items count]==0) return;
    
    NSMutableArray* fields= [NSMutableArray array];
    NSMutableString* deleteSQL;
    
    for(ZPZoteroItem* item in items){
        
        for(NSString* key in item.fields){
            [fields addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:key,[item.fields objectForKey:key],item.key, nil]
                                                          forKeys:[NSArray arrayWithObjects:@"fieldName",@"fieldValue",@"itemKey",nil]]];
        }
        if(deleteSQL == NULL){
            deleteSQL = [NSMutableString stringWithFormat:@"DELETE FROM fields WHERE (itemKey = '%@' AND fieldName NOT IN ('%@'))",item.key,
                         [item.fields.allKeys componentsJoinedByString:@"', '"]];
        }
        else{
            [deleteSQL appendFormat:@" OR (itemKey = '%@' AND fieldName NOT IN ('%@'))",item.key,
             [item.fields.allKeys componentsJoinedByString:@"', '"]];
        }
    }
    
    [self writeObjects:fields intoTable:@"fields" checkTimestamp:FALSE];

    @synchronized(self){
        [_database executeUpdate:deleteSQL];
    }

}

- (NSDictionary*) fieldsForItem:(ZPZoteroItem*)item{
    NSMutableDictionary* fields=[[NSMutableDictionary alloc] init];
    
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery:@"SELECT fieldName, fieldValue FROM fields WHERE itemKey = ? ",item.key];
        
        while([resultSet next]){
            [fields setObject:[resultSet stringForColumnIndex:1] forKey:[resultSet stringForColumnIndex:0]];
        }
        [resultSet close];
    }
    return fields;
}

- (NSArray*) creatorsForItem:(ZPZoteroItem*)item{

    NSMutableArray* creators = [[NSMutableArray alloc] init];
    
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery: @"SELECT * FROM creators WHERE itemKey = ? ORDER BY \"order\"",item.key];
        
        while([resultSet next]) {
            [creators addObject:[resultSet resultDict]];
        }
        
        [resultSet close];
    }
    return creators;

}

- (NSArray*) collectionsForItem:(ZPZoteroItem*)item{
    
    NSMutableArray* collections = [[NSMutableArray alloc] init];
    
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery: @"SELECT * FROM collectionItems, collections WHERE itemKey = ? AND collectionItems.collectionKey = collections.collectionKey ORDER BY LOWER(title)",item.key];
        
        while([resultSet next]) {
            [collections addObject:[ZPZoteroCollection dataObjectWithDictionary:[resultSet resultDict]]];
        }
        
        [resultSet close];
    }
    return collections;
    
}

- (void) addCreatorsToItem: (ZPZoteroItem*) item {
    item.creators = [self creatorsForItem:item];
}



- (void) addFieldsToItem: (ZPZoteroItem*) item  {
    item.fields = [self fieldsForItem:item];
}

- (void) addAttachmentsToItem: (ZPZoteroItem*) item  {
    
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery: @"SELECT * FROM attachments WHERE parentItemKey = ? ORDER BY title ASC",item.key];
        
        NSMutableArray* attachments = [[NSMutableArray alloc] init];
        while([resultSet next]) {
            NSDictionary* dict = [resultSet resultDict];
            ZPZoteroAttachment* attachment = [ZPZoteroAttachment dataObjectWithDictionary:dict];
            [attachments addObject:attachment];
        }
        
        [resultSet close];
        
        item.attachments = attachments;

    }
}

- (NSArray*) getCachedAttachmentsOrderedByRemovalPriority{
    
    @synchronized(self){
        
        NSMutableArray* returnArray = [NSMutableArray array];
        
        FMResultSet* resultSet = [_database executeQuery: @"SELECT * FROM attachments ORDER BY CASE WHEN lastViewed IS NULL THEN 0 ELSE 1 end, lastViewed ASC, cacheTimestamp ASC"];
        
        while([resultSet next]){
            ZPZoteroAttachment* attachment = (ZPZoteroAttachment*) [ZPZoteroAttachment dataObjectWithDictionary:[resultSet resultDict]];
            
            //If this attachment does have a file, add it to the list that we return;
            if(attachment.fileExists){
                [returnArray addObject:attachment];
            }
        }

        [resultSet close];
        
        return returnArray;
    }

}

- (NSArray*) getAttachmentsInLibrary:(NSNumber*)libraryID collection:(NSString*)collectionKey{
    @synchronized(self){

        NSMutableArray* returnArray = [NSMutableArray array];

        FMResultSet* resultSet;
        
        if(collectionKey==NULL){
            resultSet= [_database executeQuery: @"SELECT * FROM attachments, items WHERE parentItemKey = items.itemKey AND items.libraryID = ? ORDER BY attachments.cacheTimestamp DESC",libraryID];
        }
        else{
            resultSet= [_database executeQuery: @"SELECT * FROM attachments, collectionItems WHERE parentItemKey = itemsKey AND collectionKey = ? ORDER BY attachments.cacheTimestamp DESC",collectionKey];
        }
        
        while([resultSet next]){
            ZPZoteroAttachment* attachment = (ZPZoteroAttachment*) [ZPZoteroAttachment dataObjectWithDictionary:[resultSet resultDict]];

            [returnArray addObject:attachment];
        }
        
        [resultSet close];

        return returnArray;

    }
    
}

- (void) updateViewedTimestamp:(ZPZoteroAttachment*)attachment{
    @synchronized(self){
        [_database executeUpdate:@"UPDATE attachments SET lastViewed = datetime('now') WHERE itemKey = ? ",attachment.key];
    }
}

- (void) writeVersionInfoForAttachment:(ZPZoteroAttachment*)attachment{
    @synchronized(self){
        
        [_database executeUpdate:@"UPDATE attachments SET md5 = ?, versionSource = ?, versionIdentifier_server = ?, versionIdentifier_local = ? WHERE itemKey = ? ",
         attachment.md5,
         attachment.versionSource,
         attachment.versionIdentifier_server,
         attachment.versionIdentifier_local,
         attachment.key];
        
        //This is important to log because it helps troubleshooting file versioning problems.
        
/*        DDLogInfo(@"Wrote file revision info for attachment %@ (%@)into database. New values are md5 = %@, versionSource = %@, versionIdentifier_server = %@, versionIdentifier_local = %@",
                     attachment.key,
                     attachment.title,
                     attachment.md5,
                     attachment.versionSource,
                     attachment.versionIdentifier_server,
                     attachment.versionIdentifier_local
                     );*/
    }
}

- (void) addNotesToItem: (ZPZoteroItem*) item  {
    
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery: @"SELECT * FROM notes WHERE parentItemKey = ? ",item.key];
        
        NSMutableArray* notes = [[NSMutableArray alloc] init];
        while([resultSet next]) {
            [notes addObject:[ZPZoteroNote dataObjectWithDictionary:[resultSet resultDict]]];
        }
        
        [resultSet close];
        
        item.notes = notes;
        
    }
}

/*
 Retrieves all item keys and note and attachment keys from the library
 */

- (NSArray*) getAllItemKeysForLibrary:(NSNumber*)libraryID{
    
    NSMutableArray* keys = [[NSMutableArray alloc] init];
    
    
    NSString* sql = @"SELECT DISTINCT itemKey, cacheTimestamp FROM items UNION SELECT itemKey, cacheTimestamp FROM attachments UNION SELECT itemKey, cacheTimestamp FROM notes ORDER BY cacheTimestamp DESC";
    
    @synchronized(self){
        FMResultSet* resultSet;
        
        resultSet = [_database executeQuery: sql];
        
        while([resultSet next]) [keys addObject:[resultSet stringForColumnIndex:0]];
        
        [resultSet close];
    }
    
    return keys;
}

- (NSString*) getFirstItemKeyWithTimestamp:(NSString*)timestamp from:(NSNumber*)libraryID{
    @synchronized(self){
        FMResultSet* resultSet;
        
        NSString* sql = @"SELECT itemKey FROM items WHERE cacheTimestamp <= ? and libraryID = ? ORDER BY cacheTimestamp DESC LIMIT 1";
        
        resultSet = [_database executeQuery: sql, timestamp, libraryID];
        
        [resultSet next];
        NSString* ret= [resultSet stringForColumnIndex:0];
        [resultSet close];
        return ret;
    }
    
}

/*

 This is the item "search" function
 
 */

- (NSArray*) getItemKeysForLibrary:(NSNumber*)libraryID collectionKey:(NSString*)collectionKey
                      searchString:(NSString*)searchString orderField:(NSString*)orderField sortDescending:(BOOL)sortDescending{

    NSMutableArray* keys = [[NSMutableArray alloc] init];
    NSMutableArray* parameters = [[NSMutableArray alloc] init];

    
    //Build the SQL query as a string first. 
    
    NSString* sql = @"SELECT items.itemKey FROM items";
    
    if(collectionKey!=NULL)
        sql=[sql stringByAppendingString:@", collectionItems"];

    //These are available through the API, but are not fields
    NSArray* specialSortColumns = [NSArray arrayWithObjects: @"dateAdded", @"dateModified", @"creator", @"title", @"addedBy", @"numItems",nil ];

    //Sort
    if(orderField!=NULL){
        //There is an inconssitency between fields and API
        if([@"type" isEqualToString:orderField]) orderField = @"fieldType";
        
        
        if([specialSortColumns indexOfObject:orderField]==NSNotFound){
            sql=[sql stringByAppendingString:@" LEFT JOIN (SELECT itemkey, fieldValue FROM fields WHERE fieldName = ?) fields ON items.itemKey = fields.itemKey"];
            [parameters addObject:orderField];
        }
    }
    //Conditions

    sql=[sql stringByAppendingString:@" WHERE libraryID = ?"];
    [parameters addObject:libraryID];
    
    if(collectionKey!=NULL){
        sql=[sql stringByAppendingString:@" AND collectionItems.collectionKey = ? and collectionItems.itemKey = items.itemKey"];
        [parameters addObject:collectionKey];
    }

    if(searchString != NULL){
        //TODO: Make a more feature rich search query
        
        //This query is designed to minimize the amount of table scans. 
        NSMutableArray* newParameters = [NSMutableArray arrayWithArray:parameters ];

        NSString* newSql=[sql stringByAppendingString:@" AND items.title LIKE '%' || ? || '%' OR items.itemKey IN (SELECT itemKey FROM fields WHERE fieldValue LIKE '%' || ? || '%' AND itemKey IN ("];
        [newParameters addObject:searchString];
        [newParameters addObject:searchString];
        
        newSql = [newSql stringByAppendingString:sql];
        [newParameters addObjectsFromArray:parameters];
        
        newSql = [newSql stringByAppendingString:@" ) UNION SELECT itemKey FROM creators WHERE (firstName LIKE '%' || ? || '%' OR lastName LIKE '%' || ? || '%' OR shortName LIKE '%' || ? || '%') AND itemKey IN ("];
        [newParameters addObject:searchString];
        [newParameters addObject:searchString];
        [newParameters addObject:searchString];

        newSql = [newSql stringByAppendingString:sql];
        [newParameters addObjectsFromArray:parameters];
        
        newSql =[newSql stringByAppendingString:@"))"];
        
        sql=newSql;
        parameters=newParameters;
    }
    
    
    if(orderField!=NULL){
        
        
        if([specialSortColumns indexOfObject:orderField]==NSNotFound){
            sql=[sql stringByAppendingString:@" ORDER BY fieldValue"];
        }
        else if([orderField isEqualToString:@"creator"]){
            sql=[sql stringByAppendingString:@" ORDER BY fullCitation"];
        }
        else if([orderField isEqualToString:@"dateModified"]){
            sql=[sql stringByAppendingString:@" ORDER BY cacheTimestamp"];
        }
        else if([orderField isEqualToString:@"dateAdded"]){
            sql=[sql stringByAppendingString:@" ORDER BY dateAdded"];
        }
        else if([orderField isEqualToString:@"title"]){
            sql=[sql stringByAppendingString:@" ORDER BY title"];
        }

        else{
            [NSException raise:@"Not implemented" format:@"Sorting by @% has not been implemented",orderField];
        }

        if(sortDescending)
            sql=[sql stringByAppendingString:@" DESC"];
        else
            sql=[sql stringByAppendingFormat:@" ASC"];
    }
    else{
        sql=[sql stringByAppendingFormat:@" ORDER BY items.cacheTimestamp DESC"];
    }
    
    
    @synchronized(self){
        FMResultSet* resultSet;
        
        resultSet = [_database executeQuery: sql withArgumentsInArray:parameters];
        
        while([resultSet next]){
            [keys addObject:[resultSet stringForColumnIndex:0]];   
        }
        
        [resultSet close];
    }

    return keys;
}

- (NSString*) getLocalizationStringWithKey:(NSString*) key type:(NSString*) type locale:(NSString*) locale{
   
    @synchronized(self){
        FMResultSet* resultSet = [_database executeQuery: @"SELECT value FROM localization WHERE  type = ? AND key =? ",type,key];
        
        [resultSet next];
        
        NSString* ret = [resultSet stringForColumnIndex:0];
        
        [resultSet close];
        
        return ret;
    }

}

@end
