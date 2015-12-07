//
//  MPDocument.m
//  MacPass
//
//  Created by Michael Starke on 08.05.13.
//  Copyright (c) 2013 HicknHack Software GmbH. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MPDocument.h"
#import "MPAppDelegate.h"
#import "MPDocumentWindowController.h"
#import "MPDatabaseVersion.h"
#import "MPIconHelper.h"
#import "MPActionHelper.h"
#import "MPSettingsHelper.h"
#import "MPNotifications.h"
#import "MPConstants.h"
#import "MPSavePanelAccessoryViewController.h"
#import "MPTreeDelegate.h"
#import "MPTargetNodeResolving.h"

#import "KeePassKit/KeePassKit.h"

#import "NSError+Messages.h"
#import "NSString+MPPasswordCreation.h"

NSString *const MPDocumentDidAddGroupNotification         = @"com.hicknhack.macpass.MPDocumentDidAddGroupNotification";
NSString *const MPDocumentDidAddEntryNotification         = @"com.hicknhack.macpass.MPDocumentDidAddEntryNotification";

NSString *const MPDocumentDidRevertNotifiation            = @"com.hicknhack.macpass.MPDocumentDidRevertNotifiation";

NSString *const MPDocumentDidLockDatabaseNotification     = @"com.hicknhack.macpass.MPDocumentDidLockDatabaseNotification";
NSString *const MPDocumentDidUnlockDatabaseNotification   = @"com.hicknhack.macpass.MPDocumentDidUnlockDatabaseNotification";

NSString *const MPDocumentCurrentItemChangedNotification  = @"com.hicknhack.macpass.MPDocumentCurrentItemChangedNotification";

NSString *const MPDocumentWillSaveNotification            = @"com.hicknhack.macpass.MPDocumentWillSaveNotification";

NSString *const MPDocumentEntryKey                        = @"MPDocumentEntryKey";
NSString *const MPDocumentGroupKey                        = @"MPDocumentGroupKey";

@interface MPDocument () {
@private
  BOOL _didLockFile;
}

@property (nonatomic, assign) NSUInteger unlockCount;

@property (strong, nonatomic) MPSavePanelAccessoryViewController *savePanelViewController;

@property (strong, nonatomic) KPKTree *tree;
@property (weak, nonatomic) KPKGroup *root;
@property (nonatomic, strong) KPKCompositeKey *compositeKey;
@property (nonatomic, strong) NSData *encryptedData;
@property (nonatomic, strong) MPTreeDelegate *treeDelgate;
@property (copy) NSDate *lastLoadedModificationDate;

@property (assign) BOOL readOnly;
@property (strong) NSURL *lockFileURL;

@property (strong) IBOutlet NSView *warningView;
@property (weak) IBOutlet NSImageView *warningViewImage;

@end

@implementation MPDocument

+ (NSSet *)keyPathsForValuesAffectingRoot {
  return [NSSet setWithObject:NSStringFromSelector(@selector(tree))];
}

+ (KPKVersion)versionForFileType:(NSString *)fileType {
  if( NSOrderedSame == [fileType compare:MPLegacyDocumentUTI options:NSCaseInsensitiveSearch]) {
    return KPKLegacyVersion;
  }
  if( NSOrderedSame == [fileType compare:MPXMLDocumentUTI options:NSCaseInsensitiveSearch]) {
    return KPKXmlVersion;
  }
  return KPKUnknownVersion;
}

+ (NSString *)fileTypeForVersion:(KPKVersion)version {
  switch(version) {
    case KPKLegacyVersion:
      return MPLegacyDocumentUTI;
      
    case KPKXmlVersion:
      return MPXMLDocumentUTI;
      
    default:
      return @"Unknown";
  }
}

+ (BOOL)autosavesInPlace {
  return NO;
}

- (id)init {
  self = [super init];
  if(self) {
    _didLockFile = NO;
    _readOnly = NO;
  }
  return self;
}

- (void)dealloc {
  [self _cleanupLock];
}

- (instancetype)initWithType:(NSString *)typeName error:(NSError *__autoreleasing *)outError {
  self = [self init];
  if(self) {
    self.tree = [[KPKTree alloc] initWithTemplateContents];
    self.tree.metaData.rounds = [[NSUserDefaults standardUserDefaults] integerForKey:kMPSettingsKeyDefaultPasswordRounds];
  }
  return self;
}

- (void)makeWindowControllers {
  MPDocumentWindowController *windowController = [[MPDocumentWindowController alloc] init];
  [self addWindowController:windowController];
}

- (void)saveDocumentAs:(id)sender {
  /* FIXME: Use controllers for bindings to enable NSEditorRegistration. NSDocument supports this! */
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentWillSaveNotification object:self];
  [super saveDocumentAs:sender];
}

- (void)saveDocument:(id)sender {
  /* FIXME: Use controllers for bindings to enable NSEditorRegistration. NSDocument supports this! */
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentWillSaveNotification object:self];
  [super saveDocument:sender];
}

- (void)saveDocumentTo:(id)sender {
  /* FIXME: Use controllers for bindings to enable NSEditorRegistration. NSDocument supports this! */
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentWillSaveNotification object:self];
  [super saveDocumentTo:sender];
}

- (void)windowControllerDidLoadNib:(NSWindowController *)aController
{
  [super windowControllerDidLoadNib:aController];
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
  if(!self.compositeKey.hasPasswordOrKeyFile) {
    if(outError != NULL) {
      NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"NO_PASSWORD_OR_KEY_SET", "") };
      *outError = [NSError errorWithDomain:MPErrorDomain code:0 userInfo:userInfo];
    }
    return NO; // No password or key. No save possible
  }
  NSString *fileType = [self fileTypeFromLastRunSavePanel];
  KPKVersion version = [[self class] versionForFileType:fileType];
  if(version == KPKUnknownVersion) {
    if(outError != NULL) {
      NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"UNKNOWN_FILE_VERSION", "") };
      *outError = [NSError errorWithDomain:MPErrorDomain code:0 userInfo:userInfo];
    }
    return NO;
  }
  NSData *treeData = [self.tree encryptWithPassword:self.compositeKey forVersion:version error:outError];
  BOOL sucess = [treeData writeToURL:url options:0 error:outError];
  if(!sucess) {
    NSLog(@"%@", [*outError localizedDescription]);
  }
  else {
    self.lastLoadedModificationDate = [NSDate date];
  }
  return sucess;
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
  /* FIXME: Lockfile handling
   self.lockFileURL = [url URLByAppendingPathExtension:@"lock"];
   if([[NSFileManager defaultManager] fileExistsAtPath:[_lockFileURL path]]) {
   self.readOnly = YES;
   }
   else {
   [[NSFileManager defaultManager] createFileAtPath:[_lockFileURL path] contents:nil attributes:nil];
   _didLockFile = YES;
   self.readOnly = NO;
   }
   */
  /*
   Delete our old Tree, and just grab the data
   */
  self.tree = nil;
  self.encryptedData = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:outError];
  self.lastLoadedModificationDate = self.fileModificationDate;
  return YES;
}

- (BOOL)revertToContentsOfURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError {
  self.tree = nil;
  if([self readFromURL:absoluteURL ofType:typeName error:outError]) {
    [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidRevertNotifiation object:self];
    return YES;
  }
  return NO;
}

- (BOOL)isEntireFileLoaded {
  return YES;
}

- (void)close {
  [self _cleanupLock];
  /*
   We store the last url. Restored windows are automatically handled.
   If closeAllDocuments is set, all docs get this message
   */
  if(self.fileURL.isFileURL) {
    [[NSUserDefaults standardUserDefaults] setObject:self.fileURL.absoluteString forKey:kMPSettingsKeyLastDatabasePath];
  }
  self.tree = nil;
  [super close];
}

- (BOOL)shouldRunSavePanelWithAccessoryView {
  return NO;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel {
  if(!self.savePanelViewController) {
    self.savePanelViewController = [[MPSavePanelAccessoryViewController alloc] init];
  }
  self.savePanelViewController.savePanel = savePanel;
  self.savePanelViewController.document = self;
  
  [savePanel setAccessoryView:[self.savePanelViewController view]];
  [self.savePanelViewController updateView];
  
  return YES;
}

- (NSString *)fileTypeFromLastRunSavePanel {
  if(self.savePanelViewController) {
    return [[self class] fileTypeForVersion:self.savePanelViewController.selectedVersion];
  }
  return [self fileType];
}

- (void)writeXMLToURL:(NSURL *)url {
  NSData *xmlData = [self.tree xmlData];
  [xmlData writeToURL:url atomically:YES];
}

- (void)readXMLfromURL:(NSURL *)url {
  NSError *error;
  self.tree = [[KPKTree alloc] initWithXmlContentsOfURL:url error:&error];
  self.compositeKey = nil;
  self.encryptedData = nil;
}

#pragma mark Lock/Unlock/Decrypt

- (void)lockDatabase:(id)sender {
  if(self.undoManager.canUndo) {
    /* ask the user? */
    [self.undoManager removeAllActions];
  }
  [self exitSearch:self];
  NSError *error;
  /* Locking needs to be lossless hence just use the XML format */
  self.encryptedData = [self.tree encryptWithPassword:self.compositeKey forVersion:KPKXmlVersion error:&error];
  self.tree = nil;
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidLockDatabaseNotification object:self];
}

- (BOOL)unlockWithPassword:(NSString *)password keyFileURL:(NSURL *)keyFileURL error:(NSError *__autoreleasing*)error{
  self.compositeKey = [[KPKCompositeKey alloc] initWithPassword:password key:keyFileURL];
  self.tree = [[KPKTree alloc] initWithData:self.encryptedData password:self.compositeKey error:error];
  
  BOOL isUnlocked = (nil != self.tree);

  if(isUnlocked) {
    /* only clear the data if we actually do not need it anymore */
    self.encryptedData = nil;
    self.unlockCount += 1;
    [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidUnlockDatabaseNotification object:self];
    /* Make sure to only store */
    MPAppDelegate *delegate = (MPAppDelegate *)[NSApp delegate];
    if(self.compositeKey.hasKeyFile && self.compositeKey.hasPassword && delegate.isAllowedToStoreKeyFile) {
      [self _storeKeyURL:keyFileURL];
    }
  }
  else {
    self.compositeKey = nil; // clear the key?
  }
  return isUnlocked;
}

- (BOOL)changePassword:(NSString *)password keyFileURL:(NSURL *)keyFileURL {
  /* sanity check? */
  if([password length] == 0 && keyFileURL == nil) {
    return NO;
  }
  if(!self.compositeKey) {
    self.compositeKey = [[KPKCompositeKey alloc] initWithPassword:password key:keyFileURL];
  }
  else {
    [self.compositeKey setPassword:password andKeyfile:keyFileURL];
  }
  self.tree.metaData.masterKeyChanged = [NSDate date];
  /* Key change is not undoable so just recored the change as done */
  [self updateChangeCount:NSChangeDone];
  /*
   If the user opted to remember key files for documents, we should update this information.
   But it's impossible to know, if he actually saves the changes!
   */
  return YES;
}

- (NSURL *)suggestedKeyURL {
  MPAppDelegate *delegate = (MPAppDelegate *)[NSApp delegate];
  if(!delegate.isAllowedToStoreKeyFile) {
    return nil;
  }
  NSDictionary *keysForFiles = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kMPSettingsKeyRememeberdKeysForDatabases];
  NSString *keyPath = keysForFiles[[[self fileURL] path]];
  if(!keyPath) {
    return nil;
  }
  return [NSURL fileURLWithPath:keyPath];
}

#pragma mark Properties
- (KPKVersion)versionForFileType {
  return [[self class] versionForFileType:[self fileType]];
}

- (BOOL)encrypted {
  /* we have an encrypted document if there's data loaded but no tree set */
  return (nil != self.encryptedData && self.tree == nil);
}

- (KPKGroup *)root {
  return self.tree.root;
}

- (KPKGroup *)trash {
  return self.tree.trash;
}

- (KPKGroup *)templates {
  /* Caching is dangerous as we might have deleted the group */
  return [self findGroup:self.tree.metaData.entryTemplatesGroup];
}

- (BOOL)hasSearch {
  return self.searchContext != nil;
}

- (void)setTemplates:(KPKGroup *)templates {
  self.tree.templates = templates;
}

- (void)setTrash:(KPKGroup *)trash {
  self.tree.trash = trash;
}

- (void)setSelectedGroup:(KPKGroup *)selectedGroup {
  if(_selectedGroup != selectedGroup) {
    _selectedGroup = selectedGroup;
  }
  self.selectedItem = _selectedGroup;
}

- (void)setSelectedEntry:(KPKEntry *)selectedEntry {
  if(_selectedEntry != selectedEntry) {
    _selectedEntry = selectedEntry;
  }
  self.selectedItem = selectedEntry;
}

- (void)setSelectedItem:(KPKNode *)selectedItem {
  if(_selectedItem != selectedItem) {
    _selectedItem = selectedItem;
    [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentCurrentItemChangedNotification object:self];
  }
}
- (void)setTree:(KPKTree *)tree {
  if(_tree != tree) {
    _tree = tree;
    if(nil == _treeDelgate) {
      _treeDelgate = [[MPTreeDelegate alloc] initWithDocument:self];
    }
    _tree.delegate = _treeDelgate;
  }
}

#pragma mark Data Accesors

- (KPKEntry *)findEntry:(NSUUID *)uuid {
  return [self.root entryForUUID:uuid];
}

- (KPKGroup *)findGroup:(NSUUID *)uuid {
  return [self.root groupForUUID:uuid];
}

- (NSArray *)allEntries {
  return self.tree.allEntries;
}

- (NSArray *)allGroups {
  return self.tree.allGroups;
}

- (BOOL)shouldEnforcePasswordChange {
  KPKMetaData *metaData = self.tree.metaData;
  if(!metaData.enforceMasterKeyChange) { return NO; }
  return ( (24*60*60*metaData.masterKeyChangeEnforcementInterval) < -[metaData.masterKeyChanged timeIntervalSinceNow]);
}

- (BOOL)shouldRecommendPasswordChange {
  KPKMetaData *metaData = self.tree.metaData;
  if(!metaData.recommendMasterKeyChange) { return NO; }
  return ( (24*60*60*metaData.masterKeyChangeRecommendationInterval) < -[metaData.masterKeyChanged timeIntervalSinceNow]);
}

#pragma mark Data manipulation
- (KPKEntry *)createEntry:(KPKGroup *)parent {
  if(!parent) {
    return nil; // No parent
  }
  if(parent.isTrash || parent.isTrashed) {
    return nil; // no new Groups in trash
  }
  KPKEntry *newEntry = [self.tree createEntry:parent];
  newEntry.title = NSLocalizedString(@"DEFAULT_ENTRY_TITLE", @"Title for a newly created entry");
  if([self.tree.metaData.defaultUserName length] > 0) {
    newEntry.username = self.tree.metaData.defaultUserName;
  }
  NSString *defaultPassword = [NSString passwordWithDefaultSettings];
  if(defaultPassword) {
    newEntry.password = defaultPassword;
  }
  [parent addEntry:newEntry];
  [parent.undoManager setActionName:NSLocalizedString(@"ADD_ENTRY", "")];
  NSDictionary *userInfo = @{ MPDocumentEntryKey: newEntry };
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidAddEntryNotification object:self userInfo:userInfo];
  return newEntry;
}

- (KPKGroup *)createGroup:(KPKGroup *)parent {
  if(!parent) {
    return nil; // no parent!
  }
  if(parent.isTrash || parent.isTrashed) {
    return nil; // no new Groups in trash
  }
  KPKGroup *newGroup = [self.tree createGroup:parent];
  newGroup.title = NSLocalizedString(@"DEFAULT_GROUP_NAME", @"Title for a newly created group");
  newGroup.iconId = MPIconFolder;
  [parent addGroup:newGroup];
  NSDictionary *userInfo = @{ MPDocumentGroupKey : newGroup };
  [[NSNotificationCenter defaultCenter] postNotificationName:MPDocumentDidAddGroupNotification object:self userInfo:userInfo];
  return newGroup;
}

- (KPKAttribute *)createCustomAttribute:(KPKEntry *)entry {
  NSString *title = NSLocalizedString(@"DEFAULT_CUSTOM_FIELD_TITLE", @"Default Titel for new Custom-Fields");
  NSString *value = NSLocalizedString(@"DEFAULT_CUSTOM_FIELD_VALUE", @"Default Value for new Custom-Fields");
  title = [entry proposedKeyForAttributeKey:title];
  KPKAttribute *newAttribute = [[KPKAttribute alloc] initWithKey:title value:value];
  [entry addCustomAttribute:newAttribute];
  return newAttribute;
}

- (void)deleteNode:(KPKNode *)node {
  if(node.asGroup) {
    [self deleteGroup:node.asGroup];
  }
  else if(node.asEntry) {
    [self deleteEntry:node.asEntry];
  }
}

- (void)deleteEntry:(KPKEntry *)entry {
  if(!entry) {
    return; // Nothing to do;
  }
  if(entry.isTrashed) {
    [self _presentTrashAlertForItem:entry];
    return;
  }
  [entry trashOrRemove];
  BOOL permanent = (nil == self.trash);
  [self.undoManager setActionName:permanent ? NSLocalizedString(@"DELETE_ENTRY", "") : NSLocalizedString(@"TRASH_ENTRY", "Move Entry to Trash")];
  
  if(self.selectedEntry == entry) {
    self.selectedEntry = nil;
  }
}

- (void)deleteGroup:(KPKGroup *)group {
  if(!group) {
    return; // Nothing to do;
  }
  if(group.isTrashed) {
    [self _presentTrashAlertForItem:group];
    return;
  }
  [group trashOrRemove];
  BOOL permanent = (nil == self.trash);
  [self.undoManager setActionName:permanent ? NSLocalizedString(@"DELETE_GROUP", "Delete Group") : NSLocalizedString(@"TRASH_GROUP", "Move Group to Trash")];
}

#pragma mark Actions
- (void)emptyTrash:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setAlertStyle:NSWarningAlertStyle];
  [alert setMessageText:NSLocalizedString(@"WARNING_ON_EMPTY_TRASH_TITLE", "")];
  [alert setInformativeText:NSLocalizedString(@"WARNING_ON_EMPTY_TRASH_DESCRIPTION", "Informative Text displayed when clearing the Trash")];
  [alert addButtonWithTitle:NSLocalizedString(@"EMPTY_TRASH", "Empty Trash")];
  [alert addButtonWithTitle:NSLocalizedString(@"CANCEL", "Cancel")];
  
  [[alert buttons][1] setKeyEquivalent:[NSString stringWithFormat:@"%c", 0x1b]];
  
  NSWindow *window = [[self windowControllers][0] window];
  [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(_emptyTrashAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)_emptyTrashAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
  if(returnCode == NSAlertFirstButtonReturn) {
    [self _emptyTrash];
  }
}

- (void)_presentTrashAlertForItem:(KPKNode *)node {
  KPKEntry *entry = node.asEntry;
  
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setAlertStyle:NSWarningAlertStyle];
  [alert setMessageText:NSLocalizedString(@"WARNING_ON_DELETE_TRASHED_NODE_TITLE", "")];
  [alert setInformativeText:NSLocalizedString(@"WARNING_ON_DELETE_TRASHED_NODE_DESCRIPTION", "Informative Text displayed when clearing the Trash")];
  NSString *okButtonText = entry ? NSLocalizedString(@"DELETE_TRASHED_ENTRY", "Empty Trash") : NSLocalizedString(@"DELETE_TRASHED_GROUP", "Empty Trash");
  [alert addButtonWithTitle:okButtonText];
  [alert addButtonWithTitle:NSLocalizedString(@"CANCEL", "Cancel")];
  
  [[alert buttons][1] setKeyEquivalent:[NSString stringWithFormat:@"%c", 0x1b]];
  
  NSWindow *window = [[self windowControllers][0] window];
  [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(_deleteTrashedItemAlertDidEnd:returnCode:contextInfo:) contextInfo:(__bridge void *)(node)];
}

- (void)_deleteTrashedItemAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
  if(returnCode == NSAlertFirstButtonReturn) {
    KPKNode *node = (__bridge KPKNode *)(contextInfo);
    /* No undo on this operation */
    for( KPKEntry *entry in node.asGroup.childEntries) {
      [node.undoManager removeAllActionsWithTarget:entry];
    }
    for(KPKGroup *group in node.asGroup.childGroups) {
      [node.undoManager removeAllActionsWithTarget:group];
    }
    [node remove];
    [node.undoManager removeAllActionsWithTarget:node];
  }
}

- (void)createEntryFromTemplate:(id)sender {
  if(![sender respondsToSelector:@selector(representedObject)]) {
    return; // sender cannot provide useful data
  }
  id obj = [sender representedObject];
  if(![obj isKindOfClass:[NSUUID class]]) {
    return; // sender cannot provide NSUUID
  }
  NSUUID *entryUUID = [sender representedObject];
  if(entryUUID) {
    KPKEntry *templateEntry = [self findEntry:entryUUID];
    if(templateEntry && self.selectedGroup) {
      KPKEntry *copy = [templateEntry copyWithTitle:templateEntry.title options:kKPKCopyOptionNone];
      [self.selectedGroup addEntry:copy];
      [self.selectedGroup.undoManager setActionName:NSLocalizedString(@"ADD_TREMPLATE_ENTRY", "")];
    }
  }
}

- (void)duplicateEntry:(id)sender {
  KPKEntry *duplicate = [self.selectedEntry copyWithTitle:nil options:kKPKCopyOptionNone];
  [self.selectedEntry.parent addEntry:duplicate];
  [self.undoManager setActionName:NSLocalizedString(@"DUPLICATE_ENTRY", "")];
}

- (void)duplicateEntryWithOptions:(id)sender {
  
}


#pragma mark Validation
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  return [self validateUserInterfaceItem:menuItem];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem {
  return [self validateUserInterfaceItem:theItem];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)anItem {
  id<MPTargetNodeResolving> entryResolver = [NSApp targetForAction:@selector(currentTargetEntry)];
  id<MPTargetNodeResolving> groupResolver = [NSApp targetForAction:@selector(currentTargetGroup)];
  id<MPTargetNodeResolving> nodeResolver = [NSApp targetForAction:@selector(currentTargetNode)];
  
  /*
   NSLog(@"entryResolver:%@", [entryResolver class]);
   NSLog(@"groupResolver:%@", [groupResolver class]);
   NSLog(@"nodeResolver:%@", [nodeResolver class]);
   */
  
  KPKNode *targetNode = [nodeResolver currentTargetNode];
  KPKEntry *targetEntry = [entryResolver currentTargetEntry];
  KPKGroup *targetGroup = [groupResolver currentTargetGroup];
  
  /*
   if(targetNode.asGroup) {
   NSLog(@"targetNode:%@", ((KPKGroup *)targetNode).name);
   }
   else if(targetNode.asEntry) {
   NSLog(@"targetNode:%@", ((KPKEntry *)targetNode).title);
   }
   
   NSLog(@"targetGroup:%@", targetGroup.name);
   NSLog(@"tagetEntry:%@", targetEntry.title );
   */
  
  if(self.encrypted || self.isReadOnly) { return NO; }
  
  BOOL valid = targetNode ? targetNode.isEditable : YES;
  switch([MPActionHelper typeForAction:[anItem action]]) {
    case MPActionAddGroup:
      valid &= (nil != targetGroup);
      valid &= !targetGroup.isTrash;
      valid &= !targetGroup.isTrashed;
      break;
    case MPActionAddEntry:
      valid &= (nil != targetGroup);
      valid &= !targetGroup.isTrash;
      valid &= !targetGroup.isTrashed;
      break;
    case MPActionDelete:
      valid &= (nil != targetNode);
      valid &= (self.trash != targetNode);
      valid &= (targetNode != self.tree.root);
      //valid &= ![self isItemTrashed:targetNode];
      break;
    case MPActionDuplicateEntry:
      valid &= (nil != targetEntry);
      break;
    case MPActionEmptyTrash:
      valid &= ([self.trash.groups count] + [self.trash.entries count]) > 0;
      break;
    case MPActionDatabaseSettings:
    case MPActionEditPassword:
      valid &= !self.encrypted;
      break;
    case MPActionLock:
      valid &= self.compositeKey.hasPasswordOrKeyFile;
      break;
    case MPActionShowHistory:
      valid &= (nil != targetEntry);
      break;
      /* Entry View Actions */
    case MPActionCopyUsername:
      valid &= (nil != targetEntry) && ([targetEntry.username length] > 0);
      break;
    case MPActionCopyPassword:
      valid &= (nil != targetEntry ) && ([targetEntry.password length] > 0);
      break;
    case MPActionCopyURL:
    case MPActionOpenURL:
      valid &= (nil != targetEntry ) && ([targetEntry.url length] > 0);
      break;
    case MPActionPerformAutotypeForSelectedEntry:
      valid &= (nil != targetEntry);
      break;
    default:
      break;
  }
  return (valid && [super validateUserInterfaceItem:anItem]);
}

- (void)_storeKeyURL:(NSURL *)keyURL {
  if(nil == keyURL) {
    return; // no URL to store in the first place
  }
  MPAppDelegate *delegate = (MPAppDelegate *)[NSApp delegate];
  NSAssert(delegate.isAllowedToStoreKeyFile, @"We can only store if we are allowed to do so!");
  NSMutableDictionary *keysForFiles = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kMPSettingsKeyRememeberdKeysForDatabases] mutableCopy];
  if(nil == keysForFiles) {
    keysForFiles = [[NSMutableDictionary alloc] initWithCapacity:1];
  }
  keysForFiles[[[self fileURL] path]] = [keyURL path];
  [[NSUserDefaults standardUserDefaults] setObject:keysForFiles forKey:kMPSettingsKeyRememeberdKeysForDatabases];
}

- (void)_cleanupLock {
  if(_didLockFile) {
    [[NSFileManager defaultManager] removeItemAtURL:_lockFileURL error:nil];
    _didLockFile = NO;
  }
}

- (void)_emptyTrash {
  for(KPKEntry *entry in [self.trash childEntries]) {
    [[self undoManager] removeAllActionsWithTarget:entry];
  }
  for(KPKGroup *group in [self.trash childGroups]) {
    [[self undoManager] removeAllActionsWithTarget:group];
  }
  [self.trash clear];
}

#pragma mark -
#pragma mark MPTargetNodeResolving

- (KPKEntry *)currentTargetEntry {
  return self.selectedEntry;
}

- (KPKGroup *)currentTargetGroup {
  return self.selectedGroup;
}

@end
