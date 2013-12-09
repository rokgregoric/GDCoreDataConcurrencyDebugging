//
//  GDConcurrencyCheckingManagedObject.m
//  Pods
//
//  Created by Graham Dennis on 7/09/13.
//
//

// The following includes modified versions of Mike Ash's MAZeroingWeakRef/MAZeroingWeakRef.m which is licensed under BSD.
// The license for that file is as follows:
//    MAZeroingWeakRef and all code associated with it is distributed under a BSD license, as listed below.
//
//
//    Copyright (c) 2010, Michael Ash
//    All rights reserved.
//
//    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
//
//    Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
//
//    Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
//
//    Neither the name of Michael Ash nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
//
//    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


#import "GDConcurrencyCheckingManagedObject.h"

#import <CoreData/CoreData.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import <JRSwizzle/JRSwizzle.h>

#import "fishhook.h"

static pthread_mutex_t gMutex;
static NSMutableSet *gCustomSubclasses;
static NSMutableDictionary *gCustomSubclassMap; // maps regular classes to their custom subclasses

#define WhileLocked(block) do { \
    pthread_mutex_lock(&gMutex); \
    block \
    pthread_mutex_unlock(&gMutex); \
    } while(0)

static Class CreateCustomSubclass(Class class);
static void RegisterCustomSubclass(Class subclass, Class superclass);

// Public interface
Class GDConcurrencyCheckingManagedObjectClassForClass(Class managedObjectClass)
{
    Class subclass = Nil;
    WhileLocked({
        subclass = [gCustomSubclassMap objectForKey:managedObjectClass];
        if (!subclass) {
            subclass = CreateCustomSubclass(managedObjectClass);
            RegisterCustomSubclass(subclass, managedObjectClass);
        }
    });
    return subclass;
}

static void (*GDConcurrencyFailureFunction)(SEL _cmd) = NULL;

void GDCoreDataConcurrencyDebuggingSetFailureHandler(void (*failureFunction)(SEL _cmd))
{
    GDConcurrencyFailureFunction = failureFunction;
}

#pragma mark -

// COREDATA_QUEUES_AVAILABLE is defined if the NSManagedObjectContext has the concurrencyType attribute
#if (__MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_10_7) || (__IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_5_0)
    #define COREDATA_CONCURRENCY_AVAILABLE
#endif

static Class GetCustomSubclass(id obj)
{
    Class class = object_getClass(obj);
    WhileLocked({
        while(class && ![gCustomSubclasses containsObject: class])
            class = class_getSuperclass(class);
    });
    return class;
}

static Class GetRealSuperclass(id obj)
{
    Class class = GetCustomSubclass(obj);
    NSCAssert1(class, @"Coudn't find GDCoreDataConcurrencyDebugging subclass in hierarchy starting from %@, should never happen", object_getClass(obj));
    return class_getSuperclass(class);
}

static const void *ConcurrencyIdentifierKey = &ConcurrencyIdentifierKey;
static const void *ConcurrencyTypeKey = &ConcurrencyTypeKey;
static const void *ConcurrencyLastAutoreleaseBacktraceKey = &ConcurrencyLastAutoreleaseBacktraceKey;
static NSValue *ConcurrencyIdentifiersThreadDictionaryKey = nil;

#define dispatch_current_queue() ({                                                    \
      _Pragma("clang diagnostic push");                                                \
      _Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"");               \
      dispatch_queue_t queue = dispatch_get_current_queue(); \
      _Pragma("clang diagnostic pop");                                                 \
      queue;                                                                           \
    })

static BOOL ValidateConcurrencyForManagedObjectWithExpectedIdentifier(NSManagedObject *object, void *expectedConcurrencyIdentifier)
{
    NSCParameterAssert(object);
    NSCParameterAssert(expectedConcurrencyIdentifier);
    
#ifdef COREDATA_CONCURRENCY_AVAILABLE
    NSManagedObjectContextConcurrencyType concurrencyType = (NSManagedObjectContextConcurrencyType)objc_getAssociatedObject(object, ConcurrencyTypeKey);
    if (concurrencyType == NSConfinementConcurrencyType) {
#endif
        return pthread_self() == expectedConcurrencyIdentifier;
#ifdef COREDATA_CONCURRENCY_AVAILABLE
    } else if (concurrencyType == NSMainQueueConcurrencyType && [NSThread isMainThread]) {
        return YES;
    } else {
        dispatch_queue_t current_queue = dispatch_current_queue();
        if (current_queue == expectedConcurrencyIdentifier) return YES;
        NSArray *concurrencyIdentifiers = [[[NSThread currentThread] threadDictionary] objectForKey:ConcurrencyIdentifiersThreadDictionaryKey];
        return [concurrencyIdentifiers containsObject:[NSValue valueWithPointer:expectedConcurrencyIdentifier]];
    }
#endif
}

static void *GetConcurrencyIdentifierForContext(NSManagedObjectContext *context)
{
    return objc_getAssociatedObject(context, ConcurrencyIdentifierKey);
}

static void SetConcurrencyIdentifierForContext(NSManagedObjectContext *context)
{
    void *concurrencyIdentifier = GetConcurrencyIdentifierForContext(context);
    if (concurrencyIdentifier) return;
    
#ifdef COREDATA_CONCURRENCY_AVAILABLE
    if (context.concurrencyType == NSConfinementConcurrencyType) {
#endif
        concurrencyIdentifier = pthread_self();
#ifdef COREDATA_CONCURRENCY_AVAILABLE
    } else if (context.concurrencyType == NSMainQueueConcurrencyType
               || context.concurrencyType == NSPrivateQueueConcurrencyType) {
        __block dispatch_queue_t confinementQueue = NULL;
        if (context.concurrencyType == NSMainQueueConcurrencyType)
            confinementQueue = dispatch_get_main_queue();
        else {
            // Get the context queue by running a block on it
            // Note that nested -performBlockAndWait calls are safe.
            [context performBlockAndWait:^{
                confinementQueue = dispatch_current_queue();
            }];
        }
        
        concurrencyIdentifier = confinementQueue;
    } else {
        NSCParameterAssert(NO);
    }
#endif
    objc_setAssociatedObject(context, ConcurrencyIdentifierKey, concurrencyIdentifier, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL ValidateConcurrency(NSManagedObject *object, SEL _cmd)
{
    void *desiredConcurrencyIdentifier = (void *)objc_getAssociatedObject(object, ConcurrencyIdentifierKey);
    if(nil == desiredConcurrencyIdentifier) {
        return YES;
    }
    BOOL concurrencyValid = ValidateConcurrencyForManagedObjectWithExpectedIdentifier(object, desiredConcurrencyIdentifier);
    if (!concurrencyValid) {
        if (GDConcurrencyFailureFunction) GDConcurrencyFailureFunction(_cmd);
        else {
            NSLog(@"Invalid concurrent access to managed object calling '%@'; Stacktrace: %@", NSStringFromSelector(_cmd), [NSThread callStackSymbols]);
        }
    }
    return concurrencyValid;
}

#pragma mark - Dynamic Subclass method implementations

static void CustomSubclassRelease(id self, SEL _cmd)
{
    if (!ValidateConcurrency(self, _cmd) && [self retainCount] == 1) {
        // About to be deallocated, and on the wrong queue!
        // -dealloc sent on the wrong thread can be caused by an -autorelease being sent to an object causing it to live longer than it should
        // In this situation, the stacktrace of the -dealloc isn't helpful, but the stacktrace of the last -autorelease will be.
        NSString *autoreleaseStacktrace = objc_getAssociatedObject(self, ConcurrencyLastAutoreleaseBacktraceKey);
        if (autoreleaseStacktrace) {
            NSLog(@"Invalid last -release sent to managed object.  Last (invalid) autorelease stacktrace was: %@", autoreleaseStacktrace);
        }
    }
    Class superclass = GetRealSuperclass(self);
    IMP superRelease = class_getMethodImplementation(superclass, @selector(release));
    ((void (*)(id, SEL))superRelease)(self, _cmd);
}

static id CustomSubclassAutorelease(id self, SEL _cmd)
{
    if (!ValidateConcurrency(self, _cmd)) {
        objc_setAssociatedObject(self, ConcurrencyLastAutoreleaseBacktraceKey, [NSThread callStackSymbols], OBJC_ASSOCIATION_COPY);
    }
    
    Class superclass = GetRealSuperclass(self);
    IMP superAutorelease = class_getMethodImplementation(superclass, @selector(autorelease));
    return ((id (*)(id, SEL))superAutorelease)(self, _cmd);
}

static void CustomSubclassWillAccessValueForKey(id self, SEL _cmd, NSString *key)
{
    ValidateConcurrency(self, _cmd);
    Class superclass = GetRealSuperclass(self);
    IMP superWillAccessValueForKey = class_getMethodImplementation(superclass, @selector(willAccessValueForKey:));
    ((void (*)(id, SEL, id))superWillAccessValueForKey)(self, _cmd, key);
}

static void CustomSubclassWillChangeValueForKey(id self, SEL _cmd, NSString *key)
{
    ValidateConcurrency(self, _cmd);
    Class superclass = GetRealSuperclass(self);
    IMP superWillChangeValueForKey = class_getMethodImplementation(superclass, @selector(willChangeValueForKey:));
    ((void (*)(id, SEL, id))superWillChangeValueForKey)(self, _cmd, key);
}

static void CustomSubclassWillChangeValueForKeyWithSetMutationUsingObjects(id self, SEL _cmd, NSString *key, NSKeyValueSetMutationKind mutationkind, NSSet *inObjects)
{
    ValidateConcurrency(self, _cmd);
    Class superclass = GetRealSuperclass(self);
    IMP superWillChangeValueForKeyWithSetMutationUsingObjects = class_getMethodImplementation(superclass, @selector(willChangeValueForKey:withSetMutation:usingObjects:));
    ((void (*)(id, SEL, id, NSKeyValueSetMutationKind, id))superWillChangeValueForKeyWithSetMutationUsingObjects)(self, _cmd, key, mutationkind, inObjects);
}

#pragma mark - Dynamic subclass creation and registration

static Class CreateCustomSubclass(Class class)
{
    NSString *newName = [NSString stringWithFormat: @"%s_GDCoreDataConcurrencyDebugging", class_getName(class)];
    const char *newNameC = [newName UTF8String];
    
    Class subclass = objc_allocateClassPair(class, newNameC, 0);
    
    Method release = class_getInstanceMethod(class, @selector(release));
    Method autorelease = class_getInstanceMethod(class, @selector(autorelease));
    Method willAccessValueForKey = class_getInstanceMethod(class, @selector(willAccessValueForKey:));
    Method willChangeValueForKey = class_getInstanceMethod(class, @selector(willChangeValueForKey:));
    Method willChangeValueForKeyWithSetMutationUsingObjects = class_getInstanceMethod(class, @selector(willChangeValueForKey:withSetMutation:usingObjects:));
    
    // We do not override dealloc because if a context has more than 300 objects it has references to, the objects will be deallocated on a background queue
    // This would normally be considered unsafe access, but as its Core Data doing this, we must assume it to be safe.
    // We shouldn't get miss any unsafe concurrency because in normal circumstances, -release will be called on the objects, which itself would trigger deallocation.
    
    class_addMethod(subclass, @selector(release), (IMP)CustomSubclassRelease, method_getTypeEncoding(release));
    class_addMethod(subclass, @selector(autorelease), (IMP)CustomSubclassAutorelease, method_getTypeEncoding(autorelease));
    class_addMethod(subclass, @selector(willAccessValueForKey:), (IMP)CustomSubclassWillAccessValueForKey, method_getTypeEncoding(willAccessValueForKey));
    class_addMethod(subclass, @selector(willChangeValueForKey:), (IMP)CustomSubclassWillChangeValueForKey, method_getTypeEncoding(willChangeValueForKey));
    class_addMethod(subclass, @selector(willChangeValueForKey:withSetMutation:usingObjects:), (IMP)CustomSubclassWillChangeValueForKeyWithSetMutationUsingObjects, method_getTypeEncoding(willChangeValueForKeyWithSetMutationUsingObjects));
    
    objc_registerClassPair(subclass);
    
    return subclass;
}

// Our pthread mutex must be held for this function
static void RegisterCustomSubclass(Class subclass, Class superclass)
{
    [gCustomSubclassMap setObject: subclass forKey: (id <NSCopying>) superclass];
    [gCustomSubclasses addObject: subclass];
}


@interface NSManagedObject (GDCoreDataConcurrencyChecking)

- (id)gd_initWithEntity:(NSEntityDescription *)entity insertIntoManagedObjectContext:(NSManagedObjectContext *)context;

@end

@interface NSManagedObjectContext (GDCoreDataConcurrencyChecking)

#ifdef COREDATA_CONCURRENCY_AVAILABLE
- (id)gd_initWithConcurrencyType:(NSManagedObjectContextConcurrencyType)type;
#else
- (id)gd_init;
#endif

@end


struct DispatchWrapperState {
    void *context;
    void (*function)(void *);
    NSMutableArray *concurrencyIdentifiers;
    dispatch_block_t block;
};

static void DispatchTargetFunctionWrapper(void *context)
{
    struct DispatchWrapperState *state = (struct DispatchWrapperState *)context;
    
    NSMutableDictionary *threadDictionary = [[NSThread currentThread] threadDictionary];
    
    // Save the old concurrency identifier array, if there was one.
    id oldConcurrencyIdentifiers = [threadDictionary objectForKey:ConcurrencyIdentifiersThreadDictionaryKey];
    
    [threadDictionary setObject:state->concurrencyIdentifiers forKey:ConcurrencyIdentifiersThreadDictionaryKey];
    
    if (state->function)
        state->function(state->context);
    else
        state->block();
    
    // Restore the old concurrency identifier array, if there was one.
    if (oldConcurrencyIdentifiers)
        [threadDictionary setObject:oldConcurrencyIdentifiers forKey:ConcurrencyIdentifiersThreadDictionaryKey];
    else
        [threadDictionary removeObjectForKey:ConcurrencyIdentifiersThreadDictionaryKey];
}

static void DispatchSyncWrapper(dispatch_queue_t queue, void *context, void (*function)(void *), dispatch_block_t block, void *dispatch_call)
{
    // Create or obtain an array of valid concurrency identifiers for the callee block
    // This list of concurrency identifiers is basically a stack of the current set of queues that we are logically synchronously executing on,
    // even if we aren't executing on that thread.  For example, if we dispatch_sync from a background queue to the main queue, the two queues will
    // presently be running on different threads, but the block on the main queue is essentially operating on the background queue too.
    NSMutableArray *concurrencyIdentifiers = [[[NSThread currentThread] threadDictionary] objectForKey:ConcurrencyIdentifiersThreadDictionaryKey];
    if (!concurrencyIdentifiers) {
        concurrencyIdentifiers = [NSMutableArray array];
    }
    [concurrencyIdentifiers addObject:[NSValue valueWithPointer:dispatch_current_queue()]];
    
    struct DispatchWrapperState state = {context, function, concurrencyIdentifiers, block};
    
    // Passing the stack frame is OK because this is a sync function call
    if (function) {
        ((void (*)(dispatch_queue_t, void*, void (*)(void *)))dispatch_call)(queue, &state, DispatchTargetFunctionWrapper);
    } else {
        ((void (*)(dispatch_queue_t, dispatch_block_t))dispatch_call)(queue, ^{
            DispatchTargetFunctionWrapper((void *)&state);
        });
    }
}

#define DISPATCH_WRAPPER(dispatch_function)                                                                     \
static void (*original_ ## dispatch_function) (dispatch_queue_t, void *, void (*)(void *));                     \
static void wrapper_ ## dispatch_function (dispatch_queue_t queue, void *context, void (*function)(void *))     \
{                                                                                                               \
    DispatchSyncWrapper(queue, context, function, nil, original_ ## dispatch_function);                         \
}

#define DISPATCH_BLOCK_WRAPPER(dispatch_function)                                                               \
static void (*original_ ## dispatch_function) (dispatch_queue_t, dispatch_block_t);                             \
static void wrapper_ ## dispatch_function (dispatch_queue_t queue, dispatch_block_t block)                      \
{                                                                                                               \
    DispatchSyncWrapper(queue, NULL, NULL, block, original_ ## dispatch_function);                              \
}

DISPATCH_WRAPPER(dispatch_sync_f);
DISPATCH_WRAPPER(dispatch_barrier_sync_f);
DISPATCH_BLOCK_WRAPPER(dispatch_sync);
DISPATCH_BLOCK_WRAPPER(dispatch_barrier_sync);

static void EmptyFunction() {}

static void GDCoreDataConcurrencyDebuggingInitialise()
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Instrument dispatch_sync calls to keep track of the stack of synchronous queues.
        {
            ConcurrencyIdentifiersThreadDictionaryKey = [[NSValue valueWithPointer:&ConcurrencyIdentifiersThreadDictionaryKey] retain];
            
            Dl_info info;
            
            // We need to make sure every function that we're rebinding has been called in this module before they are rebound.
            // This ensures that when rebind_symbols is called, it will find the correct value for the symbol in the lookup table
            // for this module.  This is then used to set the original_dispatch_* function pointers.
            {
                dispatch_queue_t q = dispatch_queue_create("foo", DISPATCH_QUEUE_SERIAL);
                dispatch_sync_f(q, NULL, EmptyFunction);
                dispatch_barrier_sync_f(q, NULL, EmptyFunction);
                dispatch_sync(q, ^{});
                dispatch_barrier_sync(q, ^{});
                dispatch_release(q);
            }
            
            // We need to get our module name so we know which module we know has the symbol resolved.
            dladdr(EmptyFunction, &info);
            
            struct rebinding rebindings[] = {
                {"dispatch_sync_f",         wrapper_dispatch_sync_f,            info.dli_fname, (void**)&original_dispatch_sync_f},
                {"dispatch_barrier_sync_f", wrapper_dispatch_barrier_sync_f,    info.dli_fname, (void**)&original_dispatch_barrier_sync_f},
                {"dispatch_sync",           wrapper_dispatch_sync,              info.dli_fname, (void**)&original_dispatch_sync},
                {"dispatch_barrier_sync",   wrapper_dispatch_barrier_sync,      info.dli_fname, (void**)&original_dispatch_barrier_sync}
            };
            
            rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
        }
        
        // Locks for the custom subclasses
        pthread_mutexattr_t mutexattr;
        pthread_mutexattr_init(&mutexattr);
        pthread_mutexattr_settype(&mutexattr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&gMutex, &mutexattr);
        pthread_mutexattr_destroy(&mutexattr);
        
        gCustomSubclasses = [NSMutableSet new];
        gCustomSubclassMap = [NSMutableDictionary new];

    });
}

@implementation NSManagedObject (GDCoreDataConcurrencyChecking)

+ (void)load
{
    // Swizzle some methods so we can set up when a MOC or managed object is created.
    NSError *error = nil;
    if (![self jr_swizzleMethod:@selector(initWithEntity:insertIntoManagedObjectContext:) withMethod:@selector(gd_initWithEntity:insertIntoManagedObjectContext:) error:&error]) {
        NSLog(@"Failed to swizzle with error: %@", error);
    }
#ifdef COREDATA_CONCURRENCY_AVAILABLE
    if (![NSManagedObjectContext jr_swizzleMethod:@selector(initWithConcurrencyType:) withMethod:@selector(gd_initWithConcurrencyType:) error:&error]) {
#else
    if (![NSManagedObjectContext jr_swizzleMethod:@selector(init) withMethod:@selector(gd_init) error:&error]) {
#endif
        NSLog(@"Failed to swizzle with error: %@", error);
    }
}

- (id)gd_initWithEntity:(NSEntityDescription *)entity insertIntoManagedObjectContext:(NSManagedObjectContext *)context
{
    self = [self gd_initWithEntity:entity insertIntoManagedObjectContext:context];

    GDCoreDataConcurrencyDebuggingInitialise();
    
    if (context) {
        // Assign expected concurrency identifier
        objc_setAssociatedObject(self, ConcurrencyIdentifierKey, GetConcurrencyIdentifierForContext(context), OBJC_ASSOCIATION_ASSIGN);
#ifdef COREDATA_CONCURRENCY_AVAILABLE
        // Assign concurrency type in case the context is released before this object is.
        objc_setAssociatedObject(self, ConcurrencyTypeKey, (void *)context.concurrencyType, OBJC_ASSOCIATION_ASSIGN);
#endif
    }
    return self;
}

@end

@implementation NSManagedObjectContext (GDCoreDataConcurrencyChecking)

#ifdef COREDATA_CONCURRENCY_AVAILABLE
- (id)gd_initWithConcurrencyType:(NSManagedObjectContextConcurrencyType)type
{
    self = [self gd_initWithConcurrencyType:type];
#else
- (id)gd_init
{
    self = [self gd_init];
#endif
    
    GDCoreDataConcurrencyDebuggingInitialise();

    SetConcurrencyIdentifierForContext(self);

    return self;
}

@end
