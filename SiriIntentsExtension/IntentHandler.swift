//
//  IntentHandler.swift
//  SiriIntentsExtension
//
//  Created by 王登辉 on 2026/3/10.
//

import Intents

class IntentHandler: INExtension {

    override func handler(for intent: INIntent) -> Any {
        if intent is INPlayMediaIntent {
            return PlayMediaIntentHandler()
        }
        return self
    }

}
