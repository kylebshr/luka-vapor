import Vapor

struct RegisterWidgetTokenRequest: Content {
    var pushToken: WidgetPushToken
    var environment: PushEnvironment
}
