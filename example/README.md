# DownStream Example App

This is an example Flutter application demonstrating the usage of the DownStream package.

## Features Demonstrated

- Initialize DownStream with custom configuration
- Start downloads by entering a URL
- View proxy URL for streaming
- Track download progress in real-time
- View file information (name, size, mime type)
- Cancel downloads
- List all downloads
- Remove cached files

## Running the Example

1. Make sure you have Flutter installed
2. Navigate to the example directory:
   ```bash
   cd example
   ```
3. Get dependencies:
   ```bash
   flutter pub get
   ```
4. Run the app:
   ```bash
   flutter run
   ```

## Usage

1. Enter a URL of a video or file you want to download/stream
2. Click "Start Download" to begin
3. The app will display:
   - The local proxy URL
   - File information (when available)
   - Download progress
4. You can cancel the download at any time
5. View all downloads in the list below
6. Remove cached files by clicking the delete icon

## Notes

- The proxy server runs on port 8080 by default
- Files are cached in the system's temporary directory
- The app demonstrates both streaming and caching capabilities
- Progress is tracked every second for demonstration purposes
