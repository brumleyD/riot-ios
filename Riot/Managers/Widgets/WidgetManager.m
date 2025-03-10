/*
 Copyright 2017 Vector Creations Ltd
 Copyright 2019 New Vector Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "WidgetManager.h"

#import "Riot-Swift.h"

#import <MatrixKit/MatrixKit.h>

#pragma mark - Contants

NSString *const kWidgetMatrixEventTypeString  = @"m.widget";
NSString *const kWidgetModularEventTypeString = @"im.vector.modular.widgets";
NSString *const kWidgetTypeJitsi = @"jitsi";
NSString *const kWidgetTypeStickerPicker = @"m.stickerpicker";

NSString *const kWidgetManagerDidUpdateWidgetNotification = @"kWidgetManagerDidUpdateWidgetNotification";

NSString *const WidgetManagerErrorDomain = @"WidgetManagerErrorDomain";

@interface WidgetManager ()
{
    // MXSession kind of hash -> Listener for matrix events for widgets.
    // There is one per matrix session
    NSMutableDictionary<NSString*, id> *widgetEventListener;

    // Success blocks of widgets being created
    // MXSession kind of hash -> (Widget id -> `createWidget:` success block).
    NSMutableDictionary<NSString*,
        NSMutableDictionary<NSString*, void (^)(Widget *widget)>*> *successBlockForWidgetCreation;

    // Failure blocks of widgets being created
    // MXSession kind of hash -> (Widget id -> `createWidget:` failure block).
    NSMutableDictionary<NSString*,
        NSMutableDictionary<NSString*, void (^)(NSError *error)>*> *failureBlockForWidgetCreation;

    // User id -> scalar token
    NSMutableDictionary<NSString*, WidgetManagerConfig*> *configs;

    // User id -> MXSession
    NSMutableDictionary<NSString*, MXSession*> *matrixSessions;
}

@end

@implementation WidgetManager

+ (instancetype)sharedManager
{
    static WidgetManager *sharedManager = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedManager = [[WidgetManager alloc] init];
    });

    return sharedManager;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        matrixSessions = [NSMutableDictionary dictionary];
        widgetEventListener = [NSMutableDictionary dictionary];
        successBlockForWidgetCreation = [NSMutableDictionary dictionary];
        failureBlockForWidgetCreation = [NSMutableDictionary dictionary];

        [self loadConfigs];
    }
    return self;
}

- (NSArray<Widget *> *)widgetsInRoom:(MXRoom*)room withRoomState:(MXRoomState*)roomState
{
    return [self widgetsOfTypes:nil inRoom:room withRoomState:roomState];
}

- (NSArray<Widget*> *)widgetsOfTypes:(NSArray<NSString*>*)widgetTypes inRoom:(MXRoom*)room withRoomState:(MXRoomState*)roomState
{
    return [self widgetsOfTypes:widgetTypes butNotTypesOf:nil inRoom:room withRoomState:roomState];
}

- (NSArray<Widget*> *)widgetsNotOfTypes:(NSArray<NSString*>*)notWidgetTypes inRoom:(MXRoom*)room withRoomState:(MXRoomState*)roomState;
{
    return [self widgetsOfTypes:nil butNotTypesOf:notWidgetTypes inRoom:room withRoomState:roomState];
}

- (NSArray<Widget*> *)widgetsOfTypes:(NSArray<NSString*>*)widgetTypes butNotTypesOf:(NSArray<NSString*>*)notWidgetTypes inRoom:(MXRoom*)room withRoomState:(MXRoomState*)roomState;
{
    // Widget id -> widget
    NSMutableDictionary <NSString*, Widget *> *widgets = [NSMutableDictionary dictionary];

    // Get all widgets state events in the room
    NSMutableArray<MXEvent*> *widgetEvents = [NSMutableArray arrayWithArray:[roomState stateEventsWithType:kWidgetMatrixEventTypeString]];
    [widgetEvents addObjectsFromArray:[roomState stateEventsWithType:kWidgetModularEventTypeString]];

    // There can be several widgets state events for a same widget but
    // only the last one must be considered.

    // Order widgetEvents with the last event first
    [widgetEvents sortUsingComparator:^NSComparisonResult(MXEvent *event1, MXEvent *event2) {

         NSComparisonResult result = NSOrderedAscending;
         if (event2.originServerTs > event1.originServerTs)
         {
             result = NSOrderedDescending;
         }
         else if (event2.originServerTs == event1.originServerTs)
         {
             result = NSOrderedSame;
         }

         return result;
     }];

    // Create each widget from its lastest widgets state event
    for (MXEvent *widgetEvent in widgetEvents)
    {
        // Filter widget types if required
        if (widgetTypes || notWidgetTypes)
        {
            NSString *widgetType;
            MXJSONModelSetString(widgetType, widgetEvent.content[@"type"]);

            if (widgetType)
            {
                if (widgetTypes && NSNotFound == [widgetTypes indexOfObject:widgetType])
                {
                    continue;
                }
                if (notWidgetTypes && NSNotFound != [notWidgetTypes indexOfObject:widgetType])
                {
                     continue;
                }
            }
        }

        // widgetEvent.stateKey = widget id
        if (!widgets[widgetEvent.stateKey])
        {
            Widget *widget = [[Widget alloc] initWithWidgetEvent:widgetEvent inMatrixSession:room.mxSession];
            if (widget)
            {
                widgets[widget.widgetId] = widget;
            }
        }
    }

    // Return active widgets only
    NSMutableArray<Widget *> *activeWidgets = [NSMutableArray array];
    for (Widget *widget in widgets.allValues)
    {
        if (widget.isActive)
        {
            [activeWidgets addObject:widget];
        }
    }

    return activeWidgets;
}

- (NSArray<Widget*> *)userWidgets:(MXSession*)mxSession
{
    return [self userWidgets:mxSession ofTypes:nil];
}

- (NSArray<Widget*> *)userWidgets:(MXSession*)mxSession ofTypes:(NSArray<NSString*>*)widgetTypes
{
    // Get all widgets in the user account data
    NSMutableArray<Widget *> *userWidgets = [NSMutableArray array];
    for (NSDictionary *widgetEventContent in [mxSession.accountData accountDataForEventType:kMXAccountDataTypeUserWidgets].allValues)
    {
        if (![widgetEventContent isKindOfClass:NSDictionary.class])
        {
            NSLog(@"[WidgetManager] userWidgets: ERROR: invalid user widget format: %@", widgetEventContent);
            continue;
        }

        // Patch: Modular used a malformed key: "stateKey" instead of "state_key"
        // TODO: To remove once fixed server side
        NSDictionary *widgetEventContentFixed = widgetEventContent;
        if (!widgetEventContent[@"state_key"] && widgetEventContent[@"stateKey"])
        {
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:widgetEventContent];
            dict[@"state_key"] = widgetEventContent[@"stateKey"];
            widgetEventContentFixed = dict;
        }

        MXEvent *widgetEvent = [MXEvent modelFromJSON:widgetEventContentFixed];
        if (widgetEvent
            && (!widgetTypes || [widgetTypes containsObject:widgetEvent.content[@"type"]]))
        {
            Widget *widget = [[Widget alloc] initWithWidgetEvent:widgetEvent inMatrixSession:mxSession];
            if (widget)
            {
                [userWidgets addObject:widget];
            }
        }
    }

    return userWidgets;
}

- (MXHTTPOperation *)createWidget:(NSString*)widgetId
                      withContent:(NSDictionary<NSString*, NSObject*>*)widgetContent
                           inRoom:(MXRoom*)room
                          success:(void (^)(Widget *widget))success
                          failure:(void (^)(NSError *error))failure
{
    // Create an empty operation that will be mutated later
    MXHTTPOperation *operation = [[MXHTTPOperation alloc] init];

    MXWeakify(self);
    [self checkWidgetPermissionInRoom:room success:^{
        MXStrongifyAndReturnIfNil(self);

        NSString *hash = [NSString stringWithFormat:@"%p", room.mxSession];
        self->successBlockForWidgetCreation[hash][widgetId] = success;
        self->failureBlockForWidgetCreation[hash][widgetId] = failure;

        // Send a state event with the widget data
        // TODO: This API will be shortly replaced by a pure modular API
        // TODO: Move to kWidgetMatrixEventTypeString ("m.widget") type but when?
        MXHTTPOperation *operation2 = [room sendStateEventOfType:kWidgetModularEventTypeString
                                                         content:widgetContent
                                                        stateKey:widgetId
                                                         success:nil failure:failure];
        
        [operation mutateTo:operation2];

    } failure:^(NSError *error) {
        if (failure)
        {
            failure(error);
        }
    }];

    return operation;
}


- (MXHTTPOperation *)createJitsiWidgetInRoom:(MXRoom*)room
                                   withVideo:(BOOL)video
                                     success:(void (^)(Widget *jitsiWidget))success
                                     failure:(void (^)(NSError *error))failure
{
    NSString *userId = room.mxSession.myUser.userId;
    WidgetManagerConfig *config = [self configForUser:userId];
    if (!config.hasUrls)
    {
        NSLog(@"[WidgetManager] createJitsiWidgetInRoom: Error: no Integrations Manager API URL for user %@", userId);
        failure(self.errorForNonConfiguredIntegrationManager);
        return nil;
    }

    // Build data for a jitsi widget
    NSString *widgetId = [NSString stringWithFormat:@"%@_%@_%@", kWidgetTypeJitsi, room.mxSession.myUser.userId, @((uint64_t)([[NSDate date] timeIntervalSince1970] * 1000))];

    // Create a random enough jitsi conference id
    // Note: the jitsi server automatically creates conference when the conference
    // id does not exist yet
    NSString *widgetSessionId = [[[[NSProcessInfo processInfo] globallyUniqueString] substringToIndex:7] lowercaseString];
    NSString *confId = [room.roomId substringWithRange:NSMakeRange(1, [room.roomId rangeOfString:@":"].location - 1)];
    confId = [confId stringByAppendingString:widgetSessionId];

    // TODO: This url should come from modular API
    // Note: this url can be used as is inside a web container (like iframe for Riot-web)
    // Riot-iOS does not directly use it but extracts params from it (see `[JitsiViewController openWidget:withVideo:]`)
    NSString *url = [NSString stringWithFormat:@"%@/widgets/jitsi.html?confId=%@&isAudioConf=%@&displayName=$matrix_display_name&avatarUrl=$matrix_avatar_url&email=$matrix_user_id@", config.apiUrl, confId, video ? @"false" : @"true"];

    return [self createWidget:widgetId
                  withContent:@{
                                @"url": url,
                                @"type": kWidgetTypeJitsi,
                                @"data": @{
                                        @"widgetSessionId": widgetSessionId
                                        }
                                }
                       inRoom:room
                      success:success
                      failure:failure];
}

- (MXHTTPOperation *)closeWidget:(NSString *)widgetId inRoom:(MXRoom *)room success:(void (^)(void))success failure:(void (^)(NSError *))failure
{
    // Create an empty operation that will be mutated later
    MXHTTPOperation *operation = [[MXHTTPOperation alloc] init];

    [self checkWidgetPermissionInRoom:room success:^{
        
        // Send a state event with an empty content to disable the widget
        // TODO: This API will be shortly replaced by a pure modular API
        // TODO: Move to kWidgetMatrixEventTypeString ("m.widget") type but when?
        MXHTTPOperation *operation2 = [room sendStateEventOfType:kWidgetModularEventTypeString
                                  content:@{}
                                 stateKey:widgetId
                                  success:^(NSString *eventId)
                {
                    if (success)
                    {
                        success();
                    }
                } failure:failure];
        
        [operation mutateTo:operation2];

    } failure:^(NSError *error) {
        if (failure)
        {
            failure(error);
        }
    }];

    return operation;
}

/**
 Check user's power for widgets management in a room.
 
 @param room the room to check.
 @return an NSError if the user cannot act on widgets in this room. Else, nil.
 */
- (void)checkWidgetPermissionInRoom:(MXRoom *)room success:(dispatch_block_t)success  failure:(void (^)(NSError *))failure
{
    [room state:^(MXRoomState *roomState) {

        NSError *error;

        // Check user's power in the room
        MXRoomPowerLevels *powerLevels = roomState.powerLevels;
        NSInteger oneSelfPowerLevel = [powerLevels powerLevelOfUserWithUserID:room.mxSession.myUser.userId];

        // The user must be able to send state events to manage widgets
        if (oneSelfPowerLevel < powerLevels.stateDefault)
        {
            error = [NSError errorWithDomain:WidgetManagerErrorDomain
                                        code:WidgetManagerErrorCodeNotEnoughPower
                                    userInfo:@{
                                               NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"widget_no_power_to_manage", @"Vector", nil)
                                               }];
        }

        if (error)
        {
            failure(error);
        }
        else
        {
            success();
        }
    }];
}

- (void)addMatrixSession:(MXSession *)mxSession
{
     __weak __typeof__(self) weakSelf = self;

    matrixSessions[mxSession.matrixRestClient.credentials.userId] = mxSession;

    NSString *hash = [NSString stringWithFormat:@"%p", mxSession];

    id listener = [mxSession listenToEventsOfTypes:@[kWidgetMatrixEventTypeString, kWidgetModularEventTypeString] onEvent:^(MXEvent *event, MXTimelineDirection direction, id customObject) {

        typeof(self) self = weakSelf;

        if (self && direction == MXTimelineDirectionForwards)
        {
            // stateKey = widgetId
            NSString *widgetId = event.stateKey;

            NSLog(@"[WidgetManager] New widget detected: %@ in %@", widgetId, event.roomId);

            Widget *widget = [[Widget alloc] initWithWidgetEvent:event inMatrixSession:mxSession];
            if (widget)
            {
                // If it is a widget we have just created, indicate its creation is complete
                if (self->successBlockForWidgetCreation[hash][widgetId])
                {
                    self->successBlockForWidgetCreation[hash][widgetId](widget);
                }

                // Broadcast the generic notification
                [[NSNotificationCenter defaultCenter] postNotificationName:kWidgetManagerDidUpdateWidgetNotification object:widget];
            }
            else
            {
                NSLog(@"[WidgetManager] Cannot decode new widget - event: %@", event);

                if (self->failureBlockForWidgetCreation[hash][widgetId])
                {
                    // If it is a widget we have just created, indicate its creation has failed somehow
                    NSError *error = [NSError errorWithDomain:WidgetManagerErrorDomain
                                                         code:WidgetManagerErrorCodeCreationFailed
                                                     userInfo:@{
                                                                NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"widget_creation_failure", @"Vector", nil)
                                                                }];

                    self->failureBlockForWidgetCreation[hash][widgetId](error);
                }
            }

            [self->successBlockForWidgetCreation[hash] removeObjectForKey:widgetId];
            [self->failureBlockForWidgetCreation[hash] removeObjectForKey:widgetId];
        }
    }];

    widgetEventListener[hash] = listener;
    successBlockForWidgetCreation[hash] = [NSMutableDictionary dictionary];
    failureBlockForWidgetCreation[hash] = [NSMutableDictionary dictionary];
}

- (void)removeMatrixSession:(MXSession *)mxSession
{
    // Remove by value in a dict
    for (NSString *key in [matrixSessions allKeysForObject:mxSession])
    {
        [matrixSessions removeObjectForKey:key];
    }

    // mxSession.myUser.userId and mxSession.matrixRestClient.credentials.userId may be nil here
    // So, use a kind of hash value instead
    NSString *hash = [NSString stringWithFormat:@"%p", mxSession];
    id listener = widgetEventListener[hash];

    [mxSession removeListener:listener];

    [widgetEventListener removeObjectForKey:hash];
    [successBlockForWidgetCreation removeObjectForKey:hash];
    [failureBlockForWidgetCreation removeObjectForKey:hash];
}

- (MXSession*)matrixSessionForUser:(NSString*)userId
{
    return matrixSessions[userId];
}

- (void)deleteDataForUser:(NSString *)userId
{
    [configs removeObjectForKey:userId];
    [self saveConfigs];
}

#pragma mark - User integrations configuration

- (WidgetManagerConfig*)createWidgetManagerConfigForUser:(NSString*)userId
{
    WidgetManagerConfig *config;

    MXSession *session = [self matrixSessionForUser:userId];

    // Find the integrations settings for the user

    // First, look at matrix account
    // TODO in another user story
    
    // Then, try to the homeserver configuration
    MXWellknownIntegrationsManager *integrationsManager = session.homeserverWellknown.integrations.managers.firstObject;
    if (integrationsManager)
    {
        config = [[WidgetManagerConfig alloc] initWithApiUrl:integrationsManager.apiUrl uiUrl:integrationsManager.uiUrl];
    }
    else
    {
        // Fallback on app settings
        config = [self createWidgetManagerConfigWithAppSettings];
    }

    return config;
}

- (WidgetManagerConfig*)createWidgetManagerConfigWithAppSettings
{
    NSString *apiUrl = [[NSUserDefaults standardUserDefaults] objectForKey:@"integrationsRestUrl"];
    NSString *uiUrl = [[NSUserDefaults standardUserDefaults] objectForKey:@"integrationsUiUrl"];

    return [[WidgetManagerConfig alloc] initWithApiUrl:apiUrl uiUrl:uiUrl];
}

#pragma mark - Modular interface

- (WidgetManagerConfig*)configForUser:(NSString*)userId
{
    // Return a default config by default
    return configs[userId] ? configs[userId] : [self createWidgetManagerConfigForUser:userId];
}

- (BOOL)hasIntegrationManagerForUser:(NSString*)userId
{
    return [self configForUser:userId].hasUrls;
}

- (void)setConfig:(WidgetManagerConfig*)config forUser:(NSString*)userId
{
    configs[userId] = config;
    [self saveConfigs];
}


- (MXHTTPOperation *)getScalarTokenForMXSession:(MXSession*)mxSession
                                       validate:(BOOL)validate
                                        success:(void (^)(NSString *scalarToken))success
                                        failure:(void (^)(NSError *error))failure;
{
    MXHTTPOperation *operation;

    __block NSString *scalarToken = [self scalarTokenForMXSession:mxSession];
    if (scalarToken)
    {
        if (!validate)
        {
            success(scalarToken);
        }
        else
        {
            operation = [self validateScalarToken:scalarToken forMXSession:mxSession complete:^(BOOL valid) {

                if (valid)
                {
                    success(scalarToken);
                }
                else
                {
                    NSLog(@"[WidgetManager] getScalarTokenForMXSession: Invalid stored token. Need to register for a new token");
                    MXHTTPOperation *operation2 = [self registerForScalarToken:mxSession success:success failure:failure];
                    [operation mutateTo:operation2];
                }

            } failure:failure];
        }
    }
    else
    {
        NSLog(@"[WidgetManager] getScalarTokenForMXSession: Need to register for a token");
        operation = [self registerForScalarToken:mxSession success:success failure:failure];
    }

    return operation;
}

- (MXHTTPOperation *)registerForScalarToken:(MXSession*)mxSession
                                    success:(void (^)(NSString *scalarToken))success
                                    failure:(void (^)(NSError *error))failure
{
    MXHTTPOperation *operation;
    NSString *userId = mxSession.myUser.userId;

    NSLog(@"[WidgetManager] registerForScalarToken");

    WidgetManagerConfig *config = [self configForUser:userId];
    if (!config.hasUrls)
    {
        NSLog(@"[WidgetManager] registerForScalarToken: Error: no Integrations Manager API URL for user %@", mxSession.myUser.userId);
        failure(self.errorForNonConfiguredIntegrationManager);
        return nil;
    }

    MXWeakify(self);
    operation = [mxSession.matrixRestClient openIdToken:^(MXOpenIdToken *tokenObject) {
        MXStrongifyAndReturnIfNil(self);

        // Exchange the token for a scalar token
        MXHTTPClient *httpClient = [[MXHTTPClient alloc] initWithBaseURL:config.apiUrl andOnUnrecognizedCertificateBlock:nil];

        MXHTTPOperation *operation2 =
        [httpClient requestWithMethod:@"POST"
                                 path:@"register?v=1.1"
                           parameters:tokenObject.JSONDictionary
                              success:^(NSDictionary *JSONResponse)
         {

             NSString *scalarToken;
             MXJSONModelSetString(scalarToken, JSONResponse[@"scalar_token"])

             config.scalarToken = scalarToken;
             self->configs[userId] = config;
             [self saveConfigs];
             
             // Validate it (this mostly checks to see if the IM needs us to agree to some terms)
             MXHTTPOperation *operation3 = [self validateScalarToken:scalarToken forMXSession:mxSession complete:^(BOOL valid) {

                 if (success)
                 {
                     success(scalarToken);
                 }

             } failure:failure];

             [operation mutateTo:operation3];

         } failure:^(NSError *error) {
             NSLog(@"[WidgetManager] registerForScalarToken: Failed to register. Error: %@", error);

             if (failure)
             {
                 // Specialise the error
                 NSError *error = [NSError errorWithDomain:WidgetManagerErrorDomain
                                                      code:WidgetManagerErrorCodeFailedToConnectToIntegrationsServer
                                                  userInfo:@{
                                                             NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"widget_integrations_server_failed_to_connect", @"Vector", nil)
                                                             }];

                 failure(error);
             }
         }];

        [operation mutateTo:operation2];

    } failure:^(NSError *error) {
        NSLog(@"[WidgetManager] registerForScalarToken. Error in openIdToken request");

        if (failure)
        {
            failure(error);
        }
    }];

    return operation;
}

- (MXHTTPOperation *)validateScalarToken:(NSString*)scalarToken forMXSession:(MXSession*)mxSession
                                complete:(void (^)(BOOL valid))complete
                                 failure:(void (^)(NSError *error))failure
{
    NSString *userId = mxSession.myUser.userId;

    WidgetManagerConfig *config = [self configForUser:userId];
    if (!config.hasUrls)
    {
        NSLog(@"[WidgetManager] validateScalarToken: Error: no Integrations Manager API URL for user %@", mxSession.myUser.userId);
        failure(self.errorForNonConfiguredIntegrationManager);
        return nil;
    }

    MXHTTPClient *httpClient = [[MXHTTPClient alloc] initWithBaseURL:config.apiUrl andOnUnrecognizedCertificateBlock:nil];

    return [httpClient requestWithMethod:@"GET"
                                    path:[NSString stringWithFormat:@"account?v=1.1&scalar_token=%@", scalarToken]
                              parameters:nil
                                 success:^(NSDictionary *JSONResponse) {

                                     NSString *userId;
                                     MXJSONModelSetString(userId, JSONResponse[@"user_id"])

                                     if ([userId isEqualToString:mxSession.myUser.userId])
                                     {
                                         complete(YES);
                                     }
                                     else
                                     {
                                         NSLog(@"[WidgetManager] validateScalarToken. Unexpected modular/account response: %@", JSONResponse);
                                         complete(NO);
                                     }

                                 } failure:^(NSError *error) {
                                     NSHTTPURLResponse *urlResponse = [MXHTTPOperation urlResponseFromError:error];

                                     NSLog(@"[WidgetManager] validateScalarToken. Error in modular/account request. statusCode: %@", @(urlResponse.statusCode));

                                     MXError *mxError = [[MXError alloc] initWithNSError:error];
                                     if ([mxError.errcode isEqualToString:kMXErrCodeStringTermsNotSigned])
                                     {
                                         NSLog(@"[WidgetManager] validateScalarToke. Error: Need to accept terms");
                                         NSError *termsNotSignedError = [NSError errorWithDomain:WidgetManagerErrorDomain
                                                                                            code:WidgetManagerErrorCodeTermsNotSigned
                                                                                        userInfo:@{
                                                                                                NSLocalizedDescriptionKey:error.userInfo[NSLocalizedDescriptionKey]
                                                                                                   }];

                                         failure(termsNotSignedError);
                                     }
                                     else if (urlResponse &&  urlResponse.statusCode / 100 != 2)
                                     {
                                         complete(NO);
                                     }
                                     else if (failure)
                                     {
                                         failure(error);
                                     }
                                 }];
}

- (BOOL)isScalarUrl:(NSString *)urlString forUser:(NSString*)userId
{
    BOOL isScalarUrl = NO;

    // TODO: Do we need to add `integrationsWidgetsUrls` to `WidgetManagerConfig`?
    NSArray<NSString*> *scalarUrlStrings = [[NSUserDefaults standardUserDefaults] objectForKey:@"integrationsWidgetsUrls"];
    if (scalarUrlStrings.count == 0)
    {
        NSString *apiUrl = [self configForUser:userId].apiUrl;
        if (apiUrl)
        {
            scalarUrlStrings = @[apiUrl];
        }
    }

    for (NSString *scalarUrlString in scalarUrlStrings)
    {
        if ([urlString hasPrefix:scalarUrlString])
        {
            isScalarUrl = YES;
            break;
        }
    }

    return isScalarUrl;
}

#pragma mark - Private methods

- (NSString *)scalarTokenForMXSession:(MXSession *)mxSession
{
    return configs[mxSession.myUser.userId].scalarToken;
}

- (void)loadConfigs
{
    NSUserDefaults *userDefaults = [MXKAppSettings standardAppSettings].sharedUserDefaults;

    NSDictionary<NSString*, NSString*> *scalarTokens = [userDefaults objectForKey:@"scalarTokens"];
    if (scalarTokens)
    {
        // Manage migration to WidgetManagerConfig
        configs = [NSMutableDictionary dictionary];
        for (NSString *userId in scalarTokens)
        {
            NSString *scalarToken = scalarTokens[userId];

            NSLog(@"[WidgetManager] migrate scalarTokens to integrationManagerConfigs for %@", userId);

            WidgetManagerConfig *config = [self createWidgetManagerConfigWithAppSettings];
            config.scalarToken = scalarToken;

            configs[userId] = config;
        }

        [self saveConfigs];
        [userDefaults removeObjectForKey:@"scalarTokens"];
    }
    else
    {
        NSData *configsData = [userDefaults objectForKey:@"integrationManagerConfigs"];
        if (configsData)
        {
            configs = [NSMutableDictionary dictionaryWithDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:configsData]];
        }

        if (!configs)
        {
            configs = [NSMutableDictionary dictionary];
        }
    }
}

- (void)saveConfigs
{
    NSUserDefaults *userDefaults = [MXKAppSettings standardAppSettings].sharedUserDefaults;
    [userDefaults setObject:[NSKeyedArchiver archivedDataWithRootObject:configs]
                     forKey:@"integrationManagerConfigs"];
}


#pragma mark - Errors

- (NSError*)errorForNonConfiguredIntegrationManager
{
    return [NSError errorWithDomain:WidgetManagerErrorDomain
                               code:WidgetManagerErrorCodeNoIntegrationsServerConfigured
                           userInfo:@{NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"widget_no_integrations_server_configured", @"Vector", nil)}];
}

@end
