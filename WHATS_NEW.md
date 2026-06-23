# What's New

## Version 2.2.5

### ML Model Download Fix

- Fixed 403 error when downloading ML models from S3 storage
- Model downloads now route through SpiralStorage presigned URL API for authenticated access
- Added `resolveDownloadURL` to SpiralStorageService for transparent S3 key-to-presigned-URL resolution
