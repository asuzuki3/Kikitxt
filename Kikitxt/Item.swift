//
//  Item.swift
//  Kikitxt
//
//  Created by SUZUKI Akinori on 2026/10/01.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
