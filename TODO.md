# Native redesign validation

- [x] Install and select Xcode 27.1; finish first-launch setup.
- [x] Validate native UI/accessibility: Duo CI suite passed; local iPhone suite and focused contrast reruns passed, as did iPad light/dark contrast and the negative control. Final Duo screenshot and fold-state tests passed on iOS 27.1 (24A94232).
- [x] Validate real iPhone Duo outer-display screenshot capture (1398 × 2034); the capture task rejects other dimensions rather than resizing.
- [x] Add and verify automated Duo inner-display/pose switching; review open, closed, and partially folded layouts with state preservation.
- [x] Capture and visually review all ten scenes on iPhone, iPad, and Duo, including light and dark appearances; validate large Dynamic Type separately.
- [x] Document Xcode 27.1 baseline and Duo migration. Retain iOS 27.0 runtime for ordinary iPhone/iPad tests; 27.1 runtime supports Duo only.

Validation evidence: 40 screenshots plus five Duo transition captures from `9ac8479` are packaged in `e2e-artifacts/app-store/tracy-app-store-0.2.8.zip`. Python: 101 tests; JavaScript: 13 tests; native core: 30 tests. Latest GitHub checks were not polled after pushing fixes.

# Completed features

- [x] Add iOS workday notifications:
  - When an automatic break is added: “I just added a break for you. You might want to take one if you haven’t already.”
  - After eight hours of working time: “You have been working for 8 hours now. Do you want to check out?”
  - Opening either notification should offer an easy way to enter the actual checkout date and time when checkout was forgotten.
- [x] Change automatic breaks across web, API, and iOS: do not add a break for a 4.x-hour day; add one only after six hours. Keep live estimates and saved entries consistent.
- [x] Remove “Saved on this device first” from the iOS edit-day view.
- [x] Support marking vacation in the iOS edit-day view and provide a general vacation action elsewhere in the app.
