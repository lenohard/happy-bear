# Favorite/Saved Tracks Feature - Implementation Plan

## Feature Overview
**Status**: 🆕 Requested (not started)  
**Description**: Add a favorite list to save especially liked tracks for later listening.

## Current Architecture Analysis

### Existing Data Models
- **AudiobookCollection**: Main collection model with tracks array
- **AudiobookTrack**: Individual track model with location, metadata, etc.
- **TrackPlaybackState**: Playback progress tracking
- **LibraryStore**: Manages collections persistence and sync

### Current UI Structure
- **LibraryView**: Shows collections
- **PlayingView**: Current playback with history
- **SourcesView**: Baidu Netdisk integration
- **CollectionDetailView**: Individual collection details

## Implementation Plan

### Phase 1: Data Model & Persistence
1. **Extend AudiobookTrack model**
   - Add `isFavorite: Bool` property (default: false)
   - Add `favoritedAt: Date?` for sorting (set when toggled on)
   - Ensure backward compatibility with existing collections

2. **Update LibraryStore**
   - Add `toggleFavorite(for:in:)` method
   - Add `favoriteTracks()` method to get all favorites
   - Add `favoriteTracksByCollection()` for grouped display
   - Update persistence to handle new properties
   - Add favorite-specific sync logic for CloudKit

### Phase 2: UI Components
1. **FavoriteToggleButton Component**
   - Reusable heart icon button with animation
   - Toggle state with visual feedback
   - Accessibility labels for screen readers

2. **Track List Integration**
   - Add favorite toggle to CollectionDetailView track rows
   - Add favorite toggle to PlayingView current track display
   - Add favorite indicator to listening history items

3. **Favorites View**
   - New section in LibraryView (not separate tab initially)
   - List of favorited tracks with collection context
   - Quick play/resume functionality
   - Empty state with helpful message

### Phase 3: Enhanced Features
1. **Smart Favorites**
   - Auto-favorite based on playback frequency
   - Recently played favorites section
   - Favorite playlists (future enhancement)

2. **Export/Import**
   - Export favorites list (future enhancement)
   - Share favorite tracks (future enhancement)

## Technical Design

### Data Model Changes
```swift
// Extend AudiobookTrack in LibraryModels.swift
struct AudiobookTrack: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var filename: String
    var location: Location
    var fileSize: Int64
    var duration: TimeInterval?
    var trackNumber: Int
    var checksum: String?
    var metadata: [String: String]
    
    // NEW: Favorite properties
    var isFavorite: Bool = false
    var favoritedAt: Date?
    
    // Update CodingKeys to include new properties
    private enum CodingKeys: String, CodingKey {
        case id, displayName, filename, location, fileSize, duration, trackNumber, checksum, metadata
        case isFavorite, favoritedAt
    }
}
```

### LibraryStore Extensions
```swift
extension LibraryStore {
    func toggleFavorite(for trackID: UUID, in collectionID: UUID) {
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        guard let trackIndex = collections[collectionIndex].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        
        var collection = collections[collectionIndex]
        var track = collection.tracks[trackIndex]
        
        track.isFavorite.toggle()
        track.favoritedAt = track.isFavorite ? Date() : nil
        
        collection.tracks[trackIndex] = track
        collection.updatedAt = Date()
        
        collections[collectionIndex] = collection
        persistCurrentSnapshot()
        
        if let syncEngine {
            Task(priority: .utility) {
                try? await syncEngine.saveRemoteCollection(collection)
            }
        }
    }
    
    func favoriteTracks() -> [AudiobookTrack] {
        collections.flatMap { collection in
            collection.tracks.filter { $0.isFavorite }
        }
        .sorted { ($0.favoritedAt ?? Date.distantPast) > ($1.favoritedAt ?? Date.distantPast) }
    }
    
    func favoriteTracksByCollection() -> [AudiobookCollection: [AudiobookTrack]] {
        var result: [AudiobookCollection: [AudiobookTrack]] = [:]
        
        for collection in collections {
            let favorites = collection.tracks.filter { $0.isFavorite }
            if !favorites.isEmpty {
                result[collection] = favorites.sorted { 
                    ($0.favoritedAt ?? Date.distantPast) > ($1.favoritedAt ?? Date.distantPast) 
                }
            }
        }
        
        return result
    }
}
```

### UI Components
1. **FavoriteToggleButton**: Reusable heart button component
2. **FavoritesView**: Dedicated favorites listing
3. **FavoriteTrackRow**: Individual favorite track display

## Localization Requirements

### New Localization Keys
```json
"favorite_tracks_title": {
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Favorite Tracks" } },
    "zh-Hans": { "stringUnit": { "state": "translated", "value": "收藏音轨" } }
  }
},
"favorite_tracks_empty": {
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "No favorite tracks yet" } },
    "zh-Hans": { "stringUnit": { "state": "translated", "value": "还没有收藏任何音轨" } }
  }
},
"add_to_favorites": {
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Add to Favorites" } },
    "zh-Hans": { "stringUnit": { "state": "translated", "value": "添加到收藏" } }
  }
},
"remove_from_favorites": {
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Remove from Favorites" } },
    "zh-Hans": { "stringUnit": { "state": "translated", "value": "从收藏中移除" } }
  }
},
"favorites_section": {
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Favorites" } },
    "zh-Hans": { "stringUnit": { "state": "translated", "value": "收藏" } }
  }
}
```

## Integration Points

### With Existing Features
- **Cache System**: Favorites should prioritize caching
- **Playback History**: Show favorites in history view
- **Search**: Include favorites in search results
- **Siri Integration**: Future enhancement for voice commands

### User Experience
- **Visual Feedback**: Heart icon animation on toggle
- **Accessibility**: Proper labels for screen readers
- **Performance**: Efficient filtering of large favorites lists

## Implementation Priority

### High Priority (MVP)
1. Basic favorite toggle functionality
2. Favorites list view
3. Persistence across app launches

### Medium Priority
1. Favorites tab in main navigation
2. Enhanced favorites UI with collection grouping
3. Smart favorites suggestions

### Low Priority
1. Export/import functionality
2. Advanced filtering and sorting
3. Integration with Siri/Shortcuts

## Testing Strategy

### Unit Tests
- Favorite toggle functionality
- Persistence layer
- UI state management

### Integration Tests
- Favorites across multiple collections
- Cache integration
- Playback from favorites

## Potential Challenges

### Data Migration
- Handling existing collections without favorite data
- Backward compatibility

### Performance
- Efficient filtering of large track libraries
- Memory management for favorites list

### User Experience
- Intuitive favorite management
- Clear visual feedback
- Accessibility compliance

## Success Metrics
- Users can easily mark tracks as favorites
- Favorites persist across app sessions
- Quick access to favorite tracks
- Positive user feedback on feature usefulness

## Progress Log
- 2025-11-05: Implemented favorite toggles in track detail and playing views, added Library favorites section, updated persistence and localization entries.
- 2025-11-05: ✅ Completed localization for favorite tracks feature:
  - Added 5 localization keys to generate_strings.py
  - Updated Localizable.xcstrings with all 91 strings (including 5 new favorite strings)
  - Generated en.lproj/Localizable.strings with English translations
  - Generated zh-Hans.lproj/Localizable.strings with Chinese translations
  - Verified build succeeds with all new localization keys
  - Committed: cdece67

## Next Steps
1. ✅ Create implementation plan (this document)
2. ✅ Analyze existing codebase structure
3. ✅ Design data model for favorite tracks
4. ✅ Implement favorite toggle UI in player view
5. ✅ Create favorites list view
6. ✅ Add persistence for favorite tracks
7. ✅ Add localization strings for favorites feature
8. ✅ Test and verify the implementation

## Implementation Order
1. **Update data models** (AudiobookTrack with favorite properties)
2. **Extend LibraryStore** with favorite management methods
3. **Add localization strings** to Localizable.xcstrings
4. **Create FavoriteToggleButton** reusable component
5. **Integrate into CollectionDetailView** track rows
6. **Integrate into PlayingView** current track display
7. **Add Favorites section** to LibraryView
8. **Test and refine** the implementation

---
*Document created: 2025-11-05*
