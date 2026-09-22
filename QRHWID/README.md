# Windows Autopilot HWID QR Code Generator

A self-contained PowerShell script that retrieves a device's Windows Autopilot hardware hash (HWID) and generates a QR code PNG image. No external modules required.

## Why?

Windows Autopilot enrollment requires the hardware hash, but exporting it usually means USB access to retrieve the CSV. This script generates a QR code that you can scan with your phone — no USB needed.

## Usage

**Local execution:**

```powershell
powershell -ExecutionPolicy Bypass -File Get-HWIDQR.ps1
```

**Remote execution (run directly from GitHub):**

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/<you>/<repo>/main/Get-HWIDQR.ps1 | iex"
```

## How It Works

1. Retrieves the device serial number via `Win32_BIOS`
2. Retrieves the hardware hash via WMI (`MDM_DevDetail_Ext01`)
3. Builds a payload in format `SERIALNUMBER/HASH`
4. Generates a QR code PNG using alphanumeric mode (EC-L, up to 4296 chars)
5. Saves the image as `<SerialNumber>.png` and opens it automatically

## Requirements

- Windows 10/11
- PowerShell 5.1+
- No external modules or internet connection needed

## Output

The script saves a PNG file named after the device serial number (e.g., `5CG8171Q0N.png`) in the same directory as the script.

## Importing into Intune

1. Scan the QR code with your phone camera
2. Copy the scanned text (format: `SERIAL/HASH`)
3. Go to **Microsoft Intune** > **Devices** > **Windows** > **Enrollment** > **Autopilot Devices** > **Import**
4. Enter the serial number and hash

## Technical Details

- **QR Mode:** Alphanumeric (5.5 bits/char, more compact than byte mode)
- **EC Level:** L (Low) for maximum data capacity
- **QR Version:** V40 (up to 4,296 alphanumeric characters)
- **QR Library:** [QRCoder](https://github.com/codebude/QRCoder) (MIT License) embedded as base64 — no DLL files on disk
- **Separator:** `/` (valid QR alphanumeric character — comma is not)

## License

MIT License. QR generation powered by [QRCoder](https://github.com/codebude/QRCoder).
