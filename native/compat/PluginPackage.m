#import "PluginPackage.h"
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <sys/stat.h>

static NSString *BWSHA256(NSData *data) {
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hash=[NSMutableString new];
    for (NSUInteger i=0;i<sizeof(digest);i++) [hash appendFormat:@"%02x",digest[i]];
    return hash;
}

static NSURL *BWPackageManifest(NSURL *folder) {
    return [folder URLByAppendingPathComponent:@"Package.plist"];
}

static NSDictionary *BWValidatePlugin(NSURL *generation) {
    NSFileManager *files=NSFileManager.defaultManager;
    struct stat entry={};
    if (lstat(generation.fileSystemRepresentation,&entry)!=0 || !S_ISDIR(entry.st_mode))
        return nil;
    NSURL *manifestURL=BWPackageManifest(generation);
    if (lstat(manifestURL.fileSystemRepresentation,&entry)!=0 || !S_ISREG(entry.st_mode) || entry.st_size>1048576)
        return nil;
    NSDictionary *manifest=[NSDictionary dictionaryWithContentsOfURL:manifestURL];
    NSString *name=manifest[@"bundle"];
    if (![name isKindOfClass:NSString.class] || !BWPreparedPluginImageName(name) ||
        ![manifest[@"image"] isEqual:BWPreparedPluginImageName(name)] || ![manifest[@"bridgeABI"] isEqual:@1] ||
        ![manifest[@"files"] isKindOfClass:NSDictionary.class])
        return nil;
    NSDictionary *hashes=manifest[@"files"];
    NSString *info=[name stringByAppendingPathComponent:@"Contents/Info.plist"];
    if (!hashes[manifest[@"image"]] || !hashes[info])
        return nil;
    NSString *contentsPrefix=[name stringByAppendingString:@"/Contents/"];
    NSMutableSet *seen=[NSMutableSet new];
    __block BOOL readable=YES;
    NSDirectoryEnumerator *tree=[files enumeratorAtURL:generation includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *error) { readable=NO; return NO; }];
    for (NSURL *file in tree) {
        if (lstat(file.fileSystemRepresentation,&entry)!=0 || S_ISLNK(entry.st_mode))
            return nil;
        if (S_ISDIR(entry.st_mode)) continue;
        NSString *relative=[file.path substringFromIndex:generation.path.length+1];
        if ([relative isEqualToString:@"Package.plist"]) continue;
        if ([file.lastPathComponent isEqualToString:@".DS_Store"] || [file.lastPathComponent hasPrefix:@"._"]) {
            continue;
        }
        if (![relative isEqualToString:manifest[@"image"]] && ![relative hasPrefix:contentsPrefix])
            return nil;
        if (!S_ISREG(entry.st_mode) || entry.st_size>UINT32_MAX ||
            ![BWSHA256([NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil]) isEqual:hashes[relative]])
            return nil;
        [seen addObject:relative];
    }
    if (!tree || !readable || seen.count!=hashes.count) return nil;
    NSDictionary *recipeTable=[NSBundle.mainBundle objectForInfoDictionaryKey:@"BWPreparedPluginRecipes"];
    NSArray *recipe=recipeTable[name];
    NSDictionary *bundleInfo=[NSDictionary dictionaryWithContentsOfURL:[generation URLByAppendingPathComponent:info]];
    if (recipe.count != 2 || ![bundleInfo[@"CFBundleIdentifier"] isEqual:recipe[0]] ||
        ![bundleInfo[@"CFBundleShortVersionString"] isEqual:recipe[1]])
        return nil;
    NSURL *imageURL=[generation URLByAppendingPathComponent:manifest[@"image"]];
    NSFileHandle *image=[NSFileHandle fileHandleForReadingFromURL:imageURL error:nil];
    NSData *headerData=[image readDataOfLength:sizeof(struct mach_header_64)];
    [image closeFile];
    struct mach_header_64 header={};
    if (headerData.length==sizeof(header)) [headerData getBytes:&header length:sizeof(header)];
    if (header.magic!=MH_MAGIC_64 || header.cputype!=CPU_TYPE_ARM64 || header.filetype!=MH_BUNDLE)
        return nil;
    return manifest;
}

static NSString *BWPackageFingerprint(NSURL *folder) {
    NSFileManager *files=NSFileManager.defaultManager;
    __block BOOL readable=YES;
    NSDirectoryEnumerator *tree=[files enumeratorAtURL:folder includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *error) { readable=NO; return NO; }];
    if (!tree) return nil;
    NSMutableArray<NSArray *> *entries=[NSMutableArray new];
    for (NSURL *item in tree) {
        struct stat entry={};
        if (lstat(item.fileSystemRepresentation,&entry)!=0 || (!S_ISREG(entry.st_mode) && !S_ISDIR(entry.st_mode)))
            return nil;
        if ([item.lastPathComponent isEqualToString:@".DS_Store"] || [item.lastPathComponent hasPrefix:@"._"]) continue;
        NSString *relative=[item.path substringFromIndex:folder.path.length+1];
        [entries addObject:@[relative,@(S_ISDIR(entry.st_mode)),@(entry.st_size),
            @(entry.st_mtimespec.tv_sec),@(entry.st_mtimespec.tv_nsec),@(entry.st_ino)]];
    }
    if (!readable) return nil;
    [entries sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) { return [left[0] compare:right[0]]; }];
    NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:entries
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return BWSHA256(encoded);
}

static BOOL BWRealDirectory(NSURL *folder) {
    struct stat entry={};
    return folder && lstat(folder.fileSystemRepresentation,&entry)==0 && S_ISDIR(entry.st_mode);
}

static NSDictionary *BWReadPackageManifest(NSURL *folder) {
    NSURL *file=BWPackageManifest(folder);
    struct stat entry={};
    if (!BWRealDirectory(folder) || lstat(file.fileSystemRepresentation,&entry)!=0 ||
        !S_ISREG(entry.st_mode) || entry.st_size>1048576) return nil;
    return [NSDictionary dictionaryWithContentsOfURL:file];
}

static NSURL *BWGeneration(NSString *uuid) {
    if (![uuid isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:uuid]) return nil;
    return [BWPreparedPluginRoot() URLByAppendingPathComponent:uuid isDirectory:YES];
}

static NSArray<NSURL *> *BWPackageFolders(NSURL *folder) {
    return [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
}

static BOOL BWMigratePackages(NSURL *source, NSDictionary *legacy) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *marker=[BWPreparedPluginRoot() URLByAppendingPathComponent:@".files-migration-v1"];
    if ([files fileExistsAtPath:marker.path]) return YES;
    NSArray<NSURL *> *folders=BWPackageFolders(source);
    if (!folders) return NO;
    NSMutableSet *present=[NSMutableSet new];
    for (NSURL *folder in folders) {
        NSString *name=BWReadPackageManifest(folder)[@"bundle"];
        if ([name isKindOfClass:NSString.class]) [present addObject:name];
    }
    for (NSString *name in legacy) {
        if (![name isKindOfClass:NSString.class] || !BWPreparedPluginImageName(name)) return NO;
        if ([present containsObject:name]) continue;
        NSURL *generation=BWGeneration(legacy[name]);
        if (!generation || ![BWValidatePlugin(generation)[@"bundle"] isEqual:name]) return NO;
        NSString *label=[name.stringByDeletingPathExtension stringByAppendingString:@" for iPad"];
        NSURL *target=[source URLByAppendingPathComponent:label isDirectory:YES];
        if ([files fileExistsAtPath:target.path]) {
            target=[source URLByAppendingPathComponent:[label stringByAppendingString:@" (Migrated)"] isDirectory:YES];
        }
        // A hidden sibling makes interrupted migration restartable without exposing a partial package.
        NSURL *temporary=[source URLByAppendingPathComponent:[@"." stringByAppendingString:NSUUID.UUID.UUIDString]];
        BOOL copied=[files copyItemAtURL:generation toURL:temporary error:nil];
        BOOL published=copied && renamex_np(temporary.fileSystemRepresentation,target.fileSystemRepresentation,RENAME_EXCL)==0;
        if (!published) {
            [files removeItemAtURL:temporary error:nil];
            return NO;
        }
    }
    return [[NSData data] writeToURL:marker options:NSDataWritingAtomic error:nil];
}

NSURL *BWPreparedPluginFilesFolder(void) {
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:@"Plug-ins" isDirectory:YES];
}

NSDictionary *BWPreparedPluginCatalog(NSDictionary *previous) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *source=BWPreparedPluginFilesFolder();
    NSURL *root=BWPreparedPluginRoot();
    if (!source || !root || ![files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    if (![files createDirectoryAtURL:source withIntermediateDirectories:YES attributes:nil error:nil] || !BWRealDirectory(source)) return nil;
    NSURL *migration=[root URLByAppendingPathComponent:@".files-migration-v1"];
    BOOL migratedBefore=[files fileExistsAtPath:migration.path];
    // The old registry is migration input only; Files owns the desired catalog.
    NSDictionary *legacy=@{};
    if (!migratedBefore || !previous) {
        NSURL *legacyURL=[root URLByAppendingPathComponent:@"Installed.plist"];
        struct stat entry={};
        if (lstat(legacyURL.fileSystemRepresentation,&entry)==0) {
            NSDictionary *registry=S_ISREG(entry.st_mode) ? [NSDictionary dictionaryWithContentsOfURL:legacyURL] : nil;
            if (!registry && !migratedBefore) return nil;
            if (registry) legacy=registry;
        } else if (errno!=ENOENT && !migratedBefore) return nil;
    }
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    if (!migratedBefore) {
        __block BOOL migrated=NO;
        [coordinator coordinateWritingItemAtURL:source options:0 error:nil byAccessor:^(NSURL *folder) {
            migrated=BWMigratePackages(folder,legacy);
        }];
        if (!migrated) return nil;
    }
    __block NSDictionary *catalog=nil;
    [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:nil byAccessor:^(NSURL *folder) {
        if (!BWRealDirectory(folder)) return;
        NSArray<NSURL *> *folders=BWPackageFolders(folder);
        if (!folders) return;
        NSMutableDictionary<NSString *,NSURL *> *candidates=[NSMutableDictionary new];
        NSMutableSet *duplicates=[NSMutableSet new];
        NSMutableSet *present=[NSMutableSet new];
        for (NSURL *candidate in folders) {
            [present addObject:candidate.lastPathComponent];
            NSString *name=BWReadPackageManifest(candidate)[@"bundle"];
            if (![name isKindOfClass:NSString.class] || !BWPreparedPluginImageName(name)) continue;
            if (candidates[name]) [duplicates addObject:name];
            else candidates[name]=candidate;
        }
        NSMutableDictionary *next=[NSMutableDictionary new];
        NSMutableSet *validLabels=[NSMutableSet new];
        for (NSString *name in candidates) {
            if ([duplicates containsObject:name]) continue;
            NSURL *candidate=candidates[name];
            NSDictionary *manifest=BWReadPackageManifest(candidate);
            if (![manifest[@"bundle"] isEqual:name]) continue;
            NSString *fingerprint=BWPackageFingerprint(candidate);
            if (!fingerprint) continue;
            NSString *idString=previous[name][@"generation"] ?: legacy[name];
            NSURL *generation=BWGeneration(idString);
            BOOL known=generation && [BWReadPackageManifest(generation) isEqual:manifest];
            if (known) {
                if (![fingerprint isEqual:previous[name][@"fingerprint"]] &&
                    ![BWValidatePlugin(candidate) isEqual:manifest]) continue;
            } else {
                idString=NSUUID.UUID.UUIDString;
                generation=BWGeneration(idString);
                if (![files copyItemAtURL:candidate toURL:generation error:nil] ||
                    ![BWValidatePlugin(generation) isEqual:manifest]) {
                    [files removeItemAtURL:generation error:nil];
                    continue;
                }
            }
            [validLabels addObject:candidate.lastPathComponent];
            next[name]=@{@"generation":idString,@"source":candidate.lastPathComponent,@"fingerprint":fingerprint};
        }
        for (NSString *name in previous) {
            NSString *label=previous[name][@"source"];
            if (!next[name] && (candidates[name] || ([present containsObject:label] && ![validLabels containsObject:label])))
                next[name]=previous[name];
        }
        if (!previous) for (NSString *name in legacy) {
            NSURL *candidate=candidates[name];
            NSURL *generation=BWGeneration(legacy[name]);
            if (!next[name] && candidate && generation && [BWReadPackageManifest(generation)[@"bundle"] isEqual:name])
                next[name]=@{@"generation":legacy[name],@"source":candidate.lastPathComponent};
        }
        catalog=next;
    }];
    return catalog;
}
