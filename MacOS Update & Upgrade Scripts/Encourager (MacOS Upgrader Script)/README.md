# Encourager MacOS Upgrade Script (with JamfHelper)

Leverages `JamfHelper` and Jamf Pro Scripts to easily display an engaging end-user message to upgrade the MacOS by providing/installing the Apple Install Assistant pkg to the user for them to install now or later (with a re-prompt)
<br />
<br />
It checks the current OS compared to the varible OS set and then curls the URL provided, once it downloads it will have the application installer open, allowing the user to install right then, when they want, or later on when they get prompted again
<br />
<br />
Note: This was designed to go from Major OS to Major OS and not minor updates. This works different than Nudge. Id still recommend Nudge in most situations https://github.com/macadmins/nudge
<br />
<br />
Future Features: I'd like to curl a progress bar for the background download via SwiftDialog but havent had time yet.
<br />
<br />
- Customizable URL, Title, Logo, message, & Buttons

## Requirements 
[Jamf Pro](https://www.jamf.com/) 
<br />
<br />


### Initial Window
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/440682a92426b6de0611e3156271bcb685b70525/Encourager%20(MacOS%20Upgrader%20Script)/images/firstwindow.png">


### Decline Window
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/440682a92426b6de0611e3156271bcb685b70525/Encourager%20(MacOS%20Upgrader%20Script)/images/declinewindow.png">


### After download Window
<img src="https://github.com/cocopuff2u/Jamf-Scripts/blob/440682a92426b6de0611e3156271bcb685b70525/Encourager%20(MacOS%20Upgrader%20Script)/images/afterdownloadwindow.png">
