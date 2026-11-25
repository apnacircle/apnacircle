/// English strings. Urdu is in app_ur.dart. Keys must match.
const Map<String, String> enStrings = {
  'appName': 'ApnaCircle',
  'chooseLanguage': 'Choose your language',
  'english': 'English',
  'urdu': 'Urdu',
  'continue': 'Continue',
  'setParentPin': 'Set parent PIN',
  'pinHint': 'Only the parent knows this PIN. It locks all settings.',
  'pinConfirm': 'Confirm PIN',
  'pinWrong': 'Wrong PIN. Try again.',
  'family': 'Family',
  'map': 'Map',
  'alerts': 'Alerts',
  'locks': 'Locks',
  'chat': 'Chat',
  'settings': 'Settings',
  'plan': 'Family plan',
  'planPrice': '\$5/year',
  'planPaidByParent': 'Only the parent pays — whole family covered.',
  'membersCount': 'Family members',
  'maxMembers': 'Maximum 10 members',
  'circleFull': 'Circle is full (10/10). Remove a member to add another.',
  'sos': 'SOS',
  'sosSent': 'SOS sent to your family!',
  'lastLocation': 'Last location',
  'offline': 'Offline',
  'online': 'Online',
  'battery': 'Battery',
  'distanceFromYou': 'Distance from you',
  'incomingCallSim': 'Incoming call · SIM',
  'callerDistance': 'Caller distance from you',
  'locationLocked': 'Location is locked by parent',
  'locationLockAlert': 'Location was turned off — parent has been alerted.',
  'addApp': 'Add any other app yourself',
  'addAppHint': 'Type any app name to lock it, e.g. Snapchat or a game.',
  'addAndLock': 'Add & Lock',
  'addedByParent': 'Added by parent',
  'paymentMethods': 'Ways to pay',
  'pakistan': 'Pakistan',
  'international': 'International',
  'noRealPayment': 'Demo only — no real payment is taken here.',
  'alwaysLock': 'Always lock',
  'timeLock': 'Time lock',
  'timeLockNote':
      'Set the time once — it auto-locks and auto-unlocks every scheduled day.',
  'lockedNow': 'Locked now',
  'openNow': 'Open now',
  'lockedAllTime': 'Locked all the time',
  'setOnceRepeats': 'set once — repeats automatically',
  'everyDay': 'Every day',
  // 7-day free trial (22 Nov 2026).
  'trialTitle': '7-day free trial',
  'trialNotStarted':
      'Try the full Family plan free for 7 days — no payment needed. One trial per phone.',
  'startTrial': 'Start 7-day free trial',
  'trialActive': 'Free trial active',
  'daysLeft': 'days left',
  'trialEndsOn': 'Trial ends on',
  'trialExpired': 'Your free trial has ended',
  'trialExpiredNote':
      'Subscribe to keep using the Family plan — your circle and its data stay as they are.',
  'trialAlreadyUsed': 'The free trial was already used for this circle.',
  'trialStarted':
      'Free trial started — enjoy the full Family plan for 7 days!',
  'subscribe': 'Subscribe — \$5/year',
  'subscribeSoon':
      'Subscriptions are coming soon with Google Play Billing. No payment is taken here yet.',
  // Device Admin — uninstall protection (v0.5).
  'deviceAdmin': 'Uninstall protection (Device Admin)',
  'deviceAdminOn':
      'Protection ON — the app cannot be uninstalled without turning this off first.',
  'deviceAdminOff': 'Protection OFF — the app can be uninstalled normally.',
  'deviceAdminNote':
      'Device Admin cannot truly block uninstall on modern Android — it forces an extra deactivation step and alerts your parent when that happens. Protection is enforced on the phone itself by Android, so it works even with the internet off.',
  'enableProtection': 'Turn on protection',
  'disableProtection': 'Turn off protection',
  'adminDisabledAlert':
      'Device admin was turned off — your parent has been alerted.',
  // SIM-change alert (v0.5).
  'simCheck': 'SIM-change alert',
  'simCheckOn': 'ON — a different SIM after reboot alerts your family.',
  'simCheckOff': 'Could not read the SIM — check the Phone permission.',
  'simChanged': 'SIM card changed — your family has been alerted.',
  // SIM-call permissions (v0.5).
  'callPermissions': 'SIM-call caller distance',
  'callPermissionsOn': 'ON — incoming SIM calls show the caller’s distance.',
  'callPermissionsOff':
      'OFF — allow Phone + Call Log to see caller distance.',
  'callPermissionsWhy':
      'ApnaCircle needs Phone and Call Log permission to see who is calling on a normal SIM call, so it can show how far the caller is from you. WhatsApp calls are not used. The number is only used for the distance on your screen.',
  'allowPermissions': 'Allow',
  // Account delete (v0.5).
  'deleteAccount': 'Delete account',
  'deleteAccountNote':
      'Deletes your account, your profile and your member entries. Sent chat messages stay in the circle’s shared history.',
  'deleteAccountConfirm':
      'Delete your account for good? This cannot be undone.',
  'deleteAccountDone': 'Your account was deleted.',
  'deleteAccountFailed': 'Could not delete the account.',
  'signInAgainFirst': 'Sign in again first, then delete the account.',
  'delete': 'Delete',
  'cancel': 'Cancel',
  // Play Billing (v0.5).
  'billingNotAvailable':
      'Google Play Billing is not available on this device.',
  'billingProductMissing':
      'The \$5/year plan is not in the Play Store yet — it is created in Play Console before launch.',
  'billingError': 'Play Billing failed. Please try again later.',
  'billingPending': 'Purchase pending — finishing in Google Play…',
  'subscribed': 'Subscribed — Family plan active.',
  'restorePurchases': 'Restore purchases',
  'buyNow': 'Buy — \$5/year',
  // 6-digit email OTP login (v0.6).
  'emailCodeTitle': 'Email code',
  'emailCodeInfo':
      'A 6-digit code will come to your Gmail inbox — no password needed.',
  'emailCodeSend': 'Send code to Gmail',
  'emailCodeSent': 'Code sent to your Gmail — it works for 10 minutes.',
  'emailCodeHint': 'Type the 6-digit code from your Gmail inbox.',
  'emailCodeVerify': 'Verify code & Sign in',
  'emailCodeResend': 'Resend code',
  'emailCodeInvalidEmail': 'That email address does not look right.',
  'emailCodeWrong': 'Wrong code — check the Gmail and try again.',
  'emailCodeExpired': 'The code expired — ask for a new one.',
  'emailCodeNotFound': 'No code was sent to this email — ask for a new one.',
  'emailCodeTooMany': 'Too many tries — ask for a new code.',
  'emailCodeRateLimited': 'Too many codes sent — wait a while, then try again.',
  'emailCodeNotConfigured':
      'Email codes are not set up yet — sign in with your password instead.',
  'emailCodeSendFailed':
      'The code could not be sent — check your internet and try again.',
  'emailCodeNetwork': 'No internet — check the connection and try again.',
};
