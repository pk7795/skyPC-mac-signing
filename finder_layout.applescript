on run argv
    if (count of argv) is not 3 then error "usage: finder_layout.applescript MOUNT WIDTH HEIGHT"
    set mountPath to item 1 of argv
    set windowWidth to (item 2 of argv) as integer
    set windowHeight to (item 3 of argv) as integer
    set appX to (windowWidth * 27 / 100) as integer
    set applicationsX to (windowWidth * 73 / 100) as integer
    set iconY to (windowHeight * 48 / 100) as integer
    set rootAlias to POSIX file mountPath as alias
    set backgroundAlias to POSIX file (mountPath & "/.background/background.tiff") as alias

    tell application "Finder"
        set targetFolder to folder rootAlias
        open targetFolder
        -- Opening a folder is asynchronous, so Finder's front window can still
        -- be an unrelated user window here. Address this volume's own window.
        set targetWindow to container window of targetFolder
        set current view of targetWindow to icon view
        set toolbar visible of targetWindow to false
        set statusbar visible of targetWindow to false
        set bounds of targetWindow to {100, 100, 100 + windowWidth, 100 + windowHeight}
        set viewOptions to the icon view options of targetWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 14
        set background picture of viewOptions to backgroundAlias
        -- Finder populates a newly opened disk window asynchronously. On a
        -- busy machine the window can exist before its items are addressable.
        -- Retry only this idempotent layout operation and keep the wait bounded.
        set layoutReady to false
        repeat with retryIndex from 1 to 40
            try
                set position of item "SkyPC.app" of targetWindow to {appX, iconY}
                set position of item "Applications" of targetWindow to {applicationsX, iconY}
                set layoutReady to true
                exit repeat
            on error finderMessage number finderNumber
                if retryIndex is 40 then error "Finder did not load the installer items: " & finderMessage number finderNumber
                delay 0.25
            end try
        end repeat
        if layoutReady is false then error "Finder did not finish the installer layout"
        update rootAlias without registering applications
        delay 2
        close targetWindow
    end tell
end run
