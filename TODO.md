# Native redesign validation pending

- [x] Install and select Xcode 27.1; finish first-launch setup.
- [ ] Run the updated native UI/accessibility suite on iOS 27.1 (24A94232); fix forward before release.
- [ ] Validate real iPhone Duo outer-display screenshot capture (1398 × 2034); the capture task rejects other dimensions rather than resizing.
- [ ] Add and verify automated Duo inner-display/pose switching; review open, closed, and partially folded layouts with state preservation.
- [ ] Capture and visually review all ten scenes on iPhone, iPad, and Duo in both appearances; validate large Dynamic Type separately.
- [x] Document Xcode 27.1 baseline and Duo migration. Retain iOS 27.0 runtime for ordinary iPhone/iPad tests; 27.1 runtime supports Duo only.

# Completed features

- [x] Add iOS workday notifications:
  - When an automatic break is added: “I just added a break for you. You might want to take one if you haven’t already.”
  - After eight hours of working time: “You have been working for 8 hours now. Do you want to check out?”
  - Opening either notification should offer an easy way to enter the actual checkout date and time when checkout was forgotten.
- [x] Change automatic breaks across web, API, and iOS: do not add a break for a 4.x-hour day; add one only after six hours. Keep live estimates and saved entries consistent.
- [x] Remove “Saved on this device first” from the iOS edit-day view.
- [x] Support marking vacation in the iOS edit-day view and provide a general vacation action elsewhere in the app.
