//
//  FileMonitor.swift
//  Sidekick
//
//  Created by John Bean on 4/22/25.
//

import Foundation

protocol FileMonitorDelegate: AnyObject {
    func didReceive(changes: String)
}

final class FileMonitor {
    
    let url: URL
    
    let fileHandle: FileHandle
    let source: DispatchSourceFileSystemObject
    
    let onChange: () -> Void
    
    weak var delegate: FileMonitorDelegate?
    
    init(
        url: URL,
        onChange: @escaping () -> Void
    ) throws {
        self.url = url
        self.fileHandle = try FileHandle(forReadingFrom: url)
        self.onChange = onChange
        
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle.fileDescriptor,
            eventMask: .extend,
            queue: DispatchQueue.main
        )
        
        source.setEventHandler {
            let event = self.source.data
            self.process(event: event)
        }
        
        source.setCancelHandler {
            try? self.fileHandle.close()
        }
        
        fileHandle.seekToEndOfFile()
        source.resume()
    }
    
    deinit {
        source.cancel()
    }
    
    func process(event: DispatchSource.FileSystemEvent) {
        guard event.contains(.extend) else {
            return
        }
        let newData = self.fileHandle.readDataToEndOfFile()
        let string = String(data: newData, encoding: .utf8)!
        self.delegate?.didReceive(changes: string)
        onChange()
    }
    
}
