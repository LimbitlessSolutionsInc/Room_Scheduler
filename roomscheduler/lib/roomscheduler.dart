import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/foundation.dart';

import 'package:firebase_auth/firebase_auth.dart';

class ConferenceRoomScheduler extends StatefulWidget {
  ConferenceRoomScheduler();

  @override
  _ConferenceRoomSchedulerState createState() =>
      _ConferenceRoomSchedulerState();
}

String? _currentUserUid; // Store the current user's UID

// Master Keys
const List<String> masterKeys = [
  'Jxs989s9TqVrOlr3OtLZNZcGgUI2', // Nadia's key
];

class QRCodeScanner extends StatelessWidget {
  final Function(String) onScanned;

  QRCodeScanner({required this.onScanned});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: Stack(
        children: [
          MobileScanner(
            controller: MobileScannerController(
              detectionSpeed: DetectionSpeed.normal,
              facing: CameraFacing.front, // Use the front camera
              torchEnabled: true, // Enable the torch
            ),
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  debugPrint('Barcode found! ${barcode.rawValue}');

                  try {
                    // Parse the JSON and extract the UID
                    final Map<String, dynamic> scannedData =
                        json.decode(barcode.rawValue!);
                    String? extractedUid = scannedData['name']; // Extract from 'name' key

                    // Print the extracted UID to the console
                    debugPrint('Scanned UID: $extractedUid');

                    if (extractedUid != null) {
                      onScanned(extractedUid);
                      Navigator.of(context, rootNavigator: true).pop(); // Use rootNavigator here
                    } else {
                      // Handle null UID
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Invalid QR code. Please try again.')),
                      );
                    }
                  } catch (e) {
                    // Handle JSON parsing errors
                    debugPrint('Error parsing QR code: $e');
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid QR code format. Please try again.')),
                    );
                  }
                }
              }
            },
          ),
          // Overlay with a scanning area
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
            ),
            child: Center(
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.tealAccent, width: 4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text(
                    'Align QR Code Here',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _ConferenceRoomSchedulerState extends State<ConferenceRoomScheduler> {
  List<calendar.Event> _events = [];
  Map<DateTime, List<calendar.Event>> _groupedEvents = {};
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay; // Stores the selected day
  String _viewMode = 'week'; // Default to weekly view
  Timer? _timer;

  GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [calendar.CalendarApi.calendarScope],
  );

  GoogleHttpClient? _authClient;

  // Rooms and their calendar IDs
  List<Map<String, String>> rooms = [
    {
      'name': 'Conference Room',
      'id':
          'c_16dd44a23698b0f9b13f57ce5aa74d4df0363d68cdc7122be2562f3071f7c42c@group.calendar.google.com'
    },
    {
      'name': 'Clinical Room',
      'id':
          'c_c51114bdf44b007327afe78522b431e4aafd49321d0bf954364cb218f8ab3a68@group.calendar.google.com'
    },
    {
      'name': 'Training Room',
      'id':
          'c_2ac505a525ffac4751d3b5e780d8dd914dd256e45502be83bb76c324266edf3d@group.calendar.google.com'
    },
  ];

  String? _selectedRoomId;
  String _selectedRoomName = 'Conference Room';

  @override
  void initState() {
    super.initState();
    _selectedRoomId = rooms[0]['id']; // Default to Conference Room
    _authenticate();
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      setState(() {}); // Update
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _authenticate() async {
    try {
      if (kIsWeb) {
        // Web: Use Firebase Auth for UID and Google Sign-In for Calendar
        User? user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          var account = await _googleSignIn.signInSilently();
          if (account == null) {
            account = await _googleSignIn
                .signIn(); // Explicit sign-in if not already signed in
          }

          if (account != null) {
            final headers = await account.authHeaders;
            setState(() {
              _authClient = GoogleHttpClient(headers);
              _currentUserUid = user.uid;
            });
            _loadCalendarEvents(); // Load events after authentication
          } else {
            print('Google sign-in failed.');
          }
        } else {
          print('User not signed in on web.');
        }
      } else {
        // Mobile: Use QR Scanner only when scheduling/editing, not during app startup.
        var account = await _googleSignIn.signInSilently();
        if (account == null) {
          account =
              await _googleSignIn.signIn(); // Explicit sign-in if necessary
        }

        if (account != null) {
          final headers = await account.authHeaders;
          setState(() {
            _authClient = GoogleHttpClient(headers);
          });

          // User schedules or edits meetings later.
          _loadCalendarEvents();
          print('Mobile sign-in successful, ready for calendar access.');
        } else {
          print('Google sign-in failed on mobile.');
        }
      }
    } catch (error) {
      print('Error during authentication: $error');
    }
  }

  Future<void> _loadCalendarEvents() async {
    if (_authClient == null || _selectedRoomId == null) return;

    var calendarApi = calendar.CalendarApi(_authClient!);

    // Set a broader time range: for example, one month before and after the current date
    DateTime timeMin = DateTime.now().subtract(const Duration(days: 120));
    DateTime timeMax = DateTime.now().add(const Duration(days: 120));

    // Fetch all recurring instances within this time range
    var events = await calendarApi.events.list(
      _selectedRoomId!,
      timeMin: timeMin.toUtc(), // Start of the range
      timeMax: timeMax.toUtc(), // End of the range
      singleEvents: true, // Flatten recurring events
    );

    setState(() {
      _events = events.items ?? [];
      _groupEventsByDay();
    });
  }

  // Section out events based on their respective days
  void _groupEventsByDay() {
    _groupedEvents.clear();
    for (var event in _events) {
      DateTime eventDateTime =
          event.start?.dateTime?.toLocal() ?? DateTime.now();
      DateTime eventDay =
          DateTime(eventDateTime.year, eventDateTime.month, eventDateTime.day);

      if (_groupedEvents[eventDay] == null) {
        _groupedEvents[eventDay] = [];
      }
      _groupedEvents[eventDay]!.add(event);
    }
  }

  List<calendar.Event> _getEventsForDay(DateTime day) {
    return _groupedEvents[DateTime(day.year, day.month, day.day)] ?? [];
  }

  // Helper to get the first day of the current week (Sunday)
  DateTime _firstDayOfWeek(DateTime date) {
    return date.subtract(Duration(days: date.weekday % 7)); // Start from Sunday
  }

  // Helper to get the name of the month based on the focused week
  String _getMonthName(DateTime date) {
    return DateFormat('MMMM yyyy').format(date);
  }

  // Check for scheduling conflicts
  bool _isOverlapping(
      DateTime startTime, DateTime endTime, DateTime selectedDay) {
    List<calendar.Event> events = _getEventsForDay(selectedDay);

    for (var event in events) {
      DateTime existingStart =
          event.start?.dateTime?.toLocal() ?? DateTime.now();
      DateTime existingEnd = event.end?.dateTime?.toLocal() ?? DateTime.now();

      if (startTime.isBefore(existingEnd) && endTime.isAfter(existingStart)) {
        return true;
      }
    }
    return false;
  }

  // Popup for scheduling a new event
  Future<void> _scheduleEventPopup(BuildContext context, DateTime selectedDay,
    TimeOfDay startTime, TimeOfDay endTime) async {
    String? name;
    String? conflictMessage;
    String? uid;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            void _checkForConflict() {
              final DateTime startDateTime = DateTime(
                selectedDay.year,
                selectedDay.month,
                selectedDay.day,
                startTime.hour,
                startTime.minute,
              );
              final DateTime endDateTime = DateTime(
                selectedDay.year,
                selectedDay.month,
                selectedDay.day,
                endTime.hour,
                endTime.minute,
              );

              if (_isOverlapping(startDateTime, endDateTime, selectedDay)) {
                setState(() {
                  conflictMessage =
                      'The selected time overlaps with an existing event.';
                });
              } else {
                setState(() {
                  conflictMessage = null;
                });
              }
            }

            return AlertDialog(
              title: Text(
                  'Schedule Meeting on ${DateFormat.yMMMd().format(selectedDay)}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(labelText: "Title"),
                    onChanged: (value) => name = value,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text("Start Time: "),
                      TextButton(
                        onPressed: () async {
                          final TimeOfDay? pickedStartTime =
                              await showTimePicker(
                            context: context,
                            initialTime: startTime,
                          );
                          if (pickedStartTime != null) {
                            setState(() {
                              startTime = pickedStartTime;
                            });
                            _checkForConflict();
                          }
                        },
                        child: Text(startTime.format(context)),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text("End Time: "),
                      TextButton(
                        onPressed: () async {
                          final TimeOfDay? pickedEndTime =
                              await showTimePicker(
                            context: context,
                            initialTime: endTime,
                          );
                          if (pickedEndTime != null) {
                            setState(() {
                              endTime = pickedEndTime;
                            });
                            _checkForConflict();
                          }
                        },
                        child: Text(endTime.format(context)),
                      ),
                    ],
                  ),
                  if (conflictMessage != null)
                    Text(
                      conflictMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    if (name != null &&
                        startTime != null &&
                        endTime != null &&
                        conflictMessage == null) {
                      final DateTime startDateTime = DateTime(
                        selectedDay.year,
                        selectedDay.month,
                        selectedDay.day,
                        startTime.hour,
                        startTime.minute,
                      );
                      final DateTime endDateTime = DateTime(
                        selectedDay.year,
                        selectedDay.month,
                        selectedDay.day,
                        endTime.hour,
                        endTime.minute,
                      );

                      // Trigger QR Scanner on Android
                      if (!kIsWeb) {
                        await Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute(
                            builder: (context) => QRCodeScanner(
                              onScanned: (scannedUid) {
                                uid = scannedUid;
                              },
                            ),
                          ),
                        );
                      } else {
                        uid = _currentUserUid; // Use Firebase UID on Web
                      }

                      if (uid == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Failed to authenticate. Please scan the QR code.')),
                        );
                        return;
                      }

                      await _scheduleMeeting(
                          name!, startDateTime, endDateTime, uid!); // Pass UID
                      Navigator.of(context).pop();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Please fill in all fields and resolve conflicts')),
                      );
                    }
                  },
                  child: const Text('Schedule'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Passing meeting details to the Google Calendar API
  Future<void> _scheduleMeeting(String name, DateTime startDateTime,
      DateTime endDateTime, String uid) async {
    if (_authClient == null || _selectedRoomId == null) return;

    var calendarApi = calendar.CalendarApi(_authClient!);
    var event = calendar.Event(
      summary: name,
      description: uid, // Store UID in the event description
      start: calendar.EventDateTime(
          dateTime: startDateTime, timeZone: 'America/New_York'),
      end: calendar.EventDateTime(
          dateTime: endDateTime, timeZone: 'America/New_York'),
    );

    await calendarApi.events.insert(event, _selectedRoomId!);
    _loadCalendarEvents(); // Reload events after scheduling
  }

  // Room dropdown for selecting between conference rooms
  Widget _buildRoomDropdown() {
    return DropdownButtonHideUnderline(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2C),
          borderRadius: BorderRadius.circular(5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: DropdownButton<String>(
          value: _selectedRoomName,
          dropdownColor: const Color(0xFF1E1E2C), // Dropdown menu background color
          items: rooms.map((room) {
            return DropdownMenuItem<String>(
              value: room['name']!,
              child: Text(
                room['name']!,
                style: const TextStyle(color: Colors.white),
              ),
            );
          }).toList(),
          onChanged: (String? newValue) {
            setState(() {
              _selectedRoomName = newValue!;
              _selectedRoomId =
                  rooms.firstWhere((room) => room['name'] == newValue)['id'];
              _loadCalendarEvents(); // Reload
            });
          },
        ),
      ),
    );
  }

  // Main UI for the conference room scheduler
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _buildRoomDropdown(),
            const SizedBox(width: 20),
            const Expanded(
              child: Center(
                child: Text(
                  'Schedule Room',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                  _viewMode == 'week' ? Icons.view_module : Icons.view_week),
              onPressed: () {
                setState(() {
                  _viewMode = _viewMode == 'week' ? 'month' : 'week';
                });
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 1,
            child: _viewMode == 'week'
                ? _buildWeeklyView()
                : Column(
                    children: [
                      _buildCalendarHeader(),
                      Expanded(
                        child: _buildCalendarGrid(),
                      ),
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.335,
                        child: _buildSelectedDayEvents(),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // Display the list of events for the selected day
  Widget _buildSelectedDayEvents() {
    List<calendar.Event> events =
        _selectedDay != null ? _getEventsForDay(_selectedDay!) : [];

    // Sort events by their start time
    events.sort((a, b) {
      DateTime startA = a.start?.dateTime?.toLocal() ?? DateTime.now();
      DateTime startB = b.start?.dateTime?.toLocal() ?? DateTime.now();
      return startA.compareTo(startB);
    });

    return Expanded(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        color: Colors.grey[850],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selectedDay != null)
              Text(
                'Meetings for ${DateFormat.yMMMd().format(_selectedDay!)}',
                style: const TextStyle(color: Colors.white, fontSize: 24),
              )
            else
              const Text(
                'No day selected',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: events.isEmpty
                  ? const Center(
                      child: Text(
                        'No events for the selected day.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: events.length,
                      itemBuilder: (context, index) {
                        DateTime startTime = events[index]
                                .start
                                ?.dateTime
                                ?.toLocal() ??
                            DateTime.now();
                        DateTime endTime = events[index]
                                .end
                                ?.dateTime
                                ?.toLocal() ??
                            startTime.add(const Duration(hours: 1));

                        return GestureDetector(
                          onTap: () {
                            _editOrDeleteEventPopup(context, events[index]);
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 5.0),
                            padding: const EdgeInsets.all(8.0),
                            decoration: BoxDecoration(
                              color: Colors.teal.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(5.0),
                            ),
                            child: Text(
                              '${DateFormat.jm().format(startTime)} - ${DateFormat.jm().format(endTime)}: ${events[index].summary ?? 'No Title'}',
                              style: const TextStyle(
                                  fontSize: 18, color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // Method to show the denial message popup
  Future<void> _showDenialMessagePopup(
      BuildContext context, String message) async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[850],
          title: const Text(
            'Access Denied',
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            message,
            style: const TextStyle(color: Colors.redAccent),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close the dialog
              },
              child:
                  const Text('OK', style: TextStyle(color: Colors.tealAccent)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _editOrDeleteEventPopup(
    BuildContext context, calendar.Event event) async {
    String? name = event.summary;
    TimeOfDay? startTime = TimeOfDay.fromDateTime(
        event.start?.dateTime?.toLocal() ?? DateTime.now());
    TimeOfDay? endTime = TimeOfDay.fromDateTime(
        event.end?.dateTime?.toLocal() ?? DateTime.now());
    String? eventUid = event.description; // UID stored in description
    String? denialMessage; // Message for unauthorized attempts
    String? uid;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.grey[850],
              title: const Text(
                'Edit or Delete Meeting',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: "Title",
                      labelStyle: TextStyle(color: Colors.white),
                    ),
                    style: const TextStyle(color: Colors.white),
                    onChanged: (value) => name = value,
                    controller: TextEditingController(text: name),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text("Start Time: ",
                          style: TextStyle(color: Colors.white)),
                      TextButton(
                        onPressed: () async {
                          TimeOfDay? picked = await showTimePicker(
                            context: context,
                            initialTime: startTime!,
                          );
                          if (picked != null) {
                            setState(() {
                              startTime = picked;
                            });
                          }
                        },
                        child: Text(
                          startTime!.format(context),
                          style: const TextStyle(color: Colors.tealAccent),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text("End Time: ",
                          style: TextStyle(color: Colors.white)),
                      TextButton(
                        onPressed: () async {
                          TimeOfDay? picked = await showTimePicker(
                            context: context,
                            initialTime: endTime!,
                          );
                          if (picked != null) {
                            setState(() {
                              endTime = picked;
                            });
                          }
                        },
                        child: Text(
                          endTime!.format(context),
                          style: const TextStyle(color: Colors.tealAccent),
                        ),
                      ),
                    ],
                  ),
                  if (denialMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10.0),
                      child: Text(
                        denialMessage!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.tealAccent)),
                ),
                TextButton(
                  onPressed: () async {
                    // Trigger QR Scanner on Android
                    if (!kIsWeb) {
                      await Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute(
                          builder: (context) => QRCodeScanner(
                            onScanned: (scannedUid) {
                              uid = scannedUid;
                            },
                          ),
                        ),
                      );
                    } else {
                      uid = _currentUserUid; // Use Firebase UID on Web
                    }

                    if (uid == null) {
                      setState(() {
                        denialMessage =
                            'Failed to authenticate. Please scan the QR code.';
                      });
                      return;
                    }

                    // Validate UID for deletion
                    if (eventUid == uid || masterKeys.contains(uid)) {
                      await _deleteMeeting(event.id!); // Delete event
                      Navigator.of(context).pop();
                    } else {
                      setState(() {
                        denialMessage =
                            'Access denied: Invalid UID'; // Show denial message
                      });
                    }
                  },
                  child: const Text('Delete',
                      style: TextStyle(color: Colors.redAccent)),
                ),
                TextButton(
                  onPressed: () async {
                    // Trigger QR Scanner on Android
                    if (!kIsWeb) {
                      await Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute(
                          builder: (context) => QRCodeScanner(
                            onScanned: (scannedUid) {
                              uid = scannedUid;
                            },
                          ),
                        ),
                      );
                    } else {
                      uid = _currentUserUid; // Use Firebase UID on Web
                    }

                    if (uid == null) {
                      setState(() {
                        denialMessage =
                            'Failed to authenticate. Please scan the QR code.';
                      });
                      return;
                    }

                    if (name != null &&
                        startTime != null &&
                        endTime != null) {
                      DateTime startDateTime = DateTime(
                        event.start?.dateTime?.year ?? DateTime.now().year,
                        event.start?.dateTime?.month ?? DateTime.now().month,
                        event.start?.dateTime?.day ?? DateTime.now().day,
                        startTime!.hour,
                        startTime!.minute,
                      );
                      DateTime endDateTime = DateTime(
                        event.end?.dateTime?.year ?? DateTime.now().year,
                        event.end?.dateTime?.month ?? DateTime.now().month,
                        event.end?.dateTime?.day ?? DateTime.now().day,
                        endTime!.hour,
                        endTime!.minute,
                      );

                      // Validate UID for update
                      if (eventUid == uid || masterKeys.contains(uid)) {
                        await _updateMeeting(
                            event.id!, startDateTime, endDateTime, name!);
                        Navigator.of(context).pop();
                      } else {
                        setState(() {
                          denialMessage =
                              'Access denied: Invalid UID'; // Show denial message
                        });
                      }
                    }
                  },
                  child: const Text('Update',
                      style: TextStyle(color: Colors.tealAccent)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Pass updated info to Google Calendar API
  Future<void> _updateMeeting(String eventId, DateTime startDateTime,
      DateTime endDateTime, String name) async {
    if (_authClient == null) return;

    var calendarApi = calendar.CalendarApi(_authClient!);
    var updatedEvent = calendar.Event(
      summary: name, // Update event title
      start: calendar.EventDateTime(
          dateTime: startDateTime, timeZone: 'America/New_York'),
      end: calendar.EventDateTime(
          dateTime: endDateTime, timeZone: 'America/New_York'),
    );

    await calendarApi.events.patch(updatedEvent, _selectedRoomId!, eventId);
    _loadCalendarEvents(); // Reload events after updating
  }

  // Delete meeting from calendar
  Future<void> _deleteMeeting(String eventId) async {
    if (_authClient == null) return;

    var calendarApi = calendar.CalendarApi(_authClient!);
    await calendarApi.events.delete(_selectedRoomId!, eventId);
    _loadCalendarEvents(); // Reload events after deletion
  }

  // Build the weekly view calendar
  Widget _buildWeeklyView() {
    DateTime firstDayOfWeek = _firstDayOfWeek(_focusedDay);
    List<DateTime> weekDays = List.generate(7, (index) {
      return firstDayOfWeek.add(Duration(days: index));
    });

    double screenWidth = MediaQuery.of(context).size.width;
    double headerFontSize = screenWidth < 600 ? 12.0 : 14.0;
    double labelFontSize = screenWidth < 600 ? 10.0 : 12.0;

    // Determine if today is within the current week
    DateTime now = DateTime.now();
    bool isTodayInWeek = weekDays.any((day) =>
        day.year == now.year && day.month == now.month && day.day == now.day);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _focusedDay = _focusedDay.subtract(const Duration(days: 7));
                  });
                },
              ),
              Text(
                _getMonthName(_focusedDay),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () {
                  setState(() {
                    _focusedDay = _focusedDay.add(const Duration(days: 7));
                  });
                },
              ),
            ],
          ),
        ),
        Row(
          children: [
            const SizedBox(width: 60),
            ...List.generate(7, (index) {
              DateTime day = weekDays[index];
              String dayOfWeek = DateFormat('EEE').format(day);
              String dayOfMonth = DateFormat('d').format(day);

              return Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      dayOfWeek,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: headerFontSize,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      dayOfMonth,
                      style: TextStyle(
                        fontSize: labelFontSize,
                        color: Colors.grey,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
        const Divider(),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: List.generate(12, (hourIndex) {
                    final hour = 7 + hourIndex; // Assuming hours from 7 AM to 7 PM
                    return Container(
                      width: 60,
                      height: 100,
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Colors.grey, width: 0.5),
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(
                            DateFormat.j().format(
                                DateTime(_focusedDay.year, _focusedDay.month,
                                    _focusedDay.day, hour)),
                            style: TextStyle(
                                color: Colors.white, fontSize: labelFontSize),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: List.generate(7, (dayIndex) {
                      final DateTime day = weekDays[dayIndex];
                      return Expanded(
                        child: Stack(
                          children: [
                            Column(
                              children: List.generate(12, (hourIndex) {
                                final hour =
                                    7 + hourIndex; // Assuming hours from 7 AM to 7 PM
                                return GestureDetector(
                                  onTap: () {
                                    // Call the schedule event popup when the user taps on this hour block
                                    TimeOfDay startTime =
                                        TimeOfDay(hour: hour, minute: 0);
                                    TimeOfDay endTime =
                                        TimeOfDay(hour: hour + 1, minute: 0);
                                    _scheduleEventPopup(
                                        context, day, startTime, endTime);
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    height: 100,
                                    decoration: const BoxDecoration(
                                      border: Border(
                                        top: BorderSide(
                                            color: Colors.grey, width: 0.5),
                                        right: BorderSide(
                                            color: Colors.grey, width: 0.5),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                            Positioned.fill(
                              child: Stack(
                                children: _getEventsForDay(day).map((event) {
                                  final eventStartTime =
                                      event.start?.dateTime?.toLocal() ??
                                          DateTime.now();
                                  final eventEndTime =
                                      event.end?.dateTime?.toLocal() ??
                                          eventStartTime
                                              .add(const Duration(hours: 1));

                                  final minutesFromStartOfDay = eventStartTime
                                      .difference(DateTime(
                                          day.year, day.month, day.day, 7))
                                      .inMinutes;
                                  final totalDurationMinutes = eventEndTime
                                      .difference(eventStartTime)
                                      .inMinutes;

                                  final topOffset =
                                      (minutesFromStartOfDay / 60) * 100;
                                  final blockHeight =
                                      (totalDurationMinutes / 60) * 100;

                                  return Positioned(
                                    top: topOffset,
                                    left: 5,
                                    right: 5,
                                    height: blockHeight,
                                    child: GestureDetector(
                                      onTap: () {
                                        _editOrDeleteEventPopup(context, event);
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(
                                            vertical: 2),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.teal.withOpacity(0.6),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '${event.summary ?? 'No Title'} (${DateFormat.jm().format(eventStartTime)} - ${DateFormat.jm().format(eventEndTime)})',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                            // Current time indicator
                            if (isTodayInWeek &&
                                day.day == now.day &&
                                day.month == now.month &&
                                day.year == now.year)
                              Positioned(
                                top: ((now.hour - 7) * 100) +
                                    ((now.minute - 10) * (100 / 60)),
                                left: -50,
                                right: 0,
                                child: Row(
                                  children: [
                                    // Arrow
                                    Transform.translate(
                                      offset: const Offset(35, 0),
                                      child: const Icon(Icons.arrow_right,
                                          color: Colors.red, size: 35),
                                    ),
                                    // Line
                                    Expanded(
                                      child: Container(
                                        height: 2,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Header for navigating months
  Widget _buildCalendarHeader() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              setState(() {
                _focusedDay = DateTime(_focusedDay.year, _focusedDay.month - 1);
              });
            },
          ),
          Text(
            DateFormat.yMMMM().format(_focusedDay),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: () {
              setState(() {
                _focusedDay = DateTime(_focusedDay.year, _focusedDay.month + 1);
              });
            },
          ),
        ],
      ),
    );
  }

  // Build the grid layout for the monthly calendar
  Widget _buildCalendarGrid() {
    int daysInMonth =
        DateTime(_focusedDay.year, _focusedDay.month + 1, 0).day;
    DateTime firstDayOfMonth =
        DateTime(_focusedDay.year, _focusedDay.month, 1);

    int leadingEmptyDays = firstDayOfMonth.weekday % 7; // Days before the 1st
    List<Widget> dayCells =
        List.generate(leadingEmptyDays, (_) => _buildEmptyDayCell());

    // Fill in actual day cells
    for (int day = 1; day <= daysInMonth; day++) {
      DateTime dayDate = DateTime(_focusedDay.year, _focusedDay.month, day);
      dayCells.add(_buildDayCell(dayDate));
    }

    // Fill remaining days after the last day of the month to complete the grid
    while (dayCells.length % 7 != 0) {
      dayCells.add(_buildEmptyDayCell());
    }

    // Get the current screen width
    double screenWidth = MediaQuery.of(context).size.width;

    // Set the childAspectRatio based on screen width
    double aspectRatio = screenWidth < 630 ? 1 / 1.5 : 1 / 1.0;

    return GridView.count(
      crossAxisCount: 7,
      childAspectRatio: aspectRatio, // Dynamically adjust aspect ratio
      children: dayCells,
    );
  }

  // Build empty day cells with a dark grey background to make the grid look consistent
  Widget _buildEmptyDayCell() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[800],
        border: Border.all(color: Colors.grey.shade600),
      ),
    );
  }

  // Build day cells with the day number and events
  Widget _buildDayCell(DateTime day) {
    List<calendar.Event> events = _getEventsForDay(day);

    // Maximum number of events shown
    int maxEventsToShow = 4;

    double screenWidth = MediaQuery.of(context).size.width;

    if (screenWidth < 1150) {
      // If screen width is less than 1150px, just show the number of events in a circle
      return GestureDetector(
        onTap: () {
          setState(() {
            _selectedDay = day; // Highlight the selected day
          });
        },
        onDoubleTap: () {
          DateTime now = DateTime.now();
          TimeOfDay startTime = TimeOfDay(hour: now.hour, minute: now.minute);
          TimeOfDay endTime =
              TimeOfDay(hour: now.hour + 1, minute: now.minute);
          _scheduleEventPopup(context, day, startTime,
              endTime); // Trigger meeting creation on double tap
        },
        child: Container(
          decoration: BoxDecoration(
            color: _selectedDay == day
                ? Colors.teal.withOpacity(0.6)
                : Colors.grey[800], // Highlight selected day
            border: Border.all(color: Colors.grey.shade600),
          ),
          padding: const EdgeInsets.all(8),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: day.month == _focusedDay.month
                        ? Colors.white
                        : Colors.grey.shade400,
                  ),
                ),
              ),
              if (events.isNotEmpty)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.teal.withOpacity(0.8),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${events.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // Show events based on screen size for larger screens
    if (screenWidth < 1420) {
      maxEventsToShow = 2; // If the screen width is less than 1420px, show 2 events
    } else if (screenWidth < 1690) {
      maxEventsToShow = 3; // If the screen width is less than 1690px, show 3 events
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedDay = day; // Highlight the selected day
        });
      },
      onDoubleTap: () {
        DateTime now = DateTime.now();
        TimeOfDay startTime = TimeOfDay(hour: now.hour, minute: now.minute);
        TimeOfDay endTime =
            TimeOfDay(hour: now.hour + 1, minute: now.minute);
        _scheduleEventPopup(context, day, startTime,
            endTime); // Trigger meeting creation on double tap
      },
      child: Container(
        decoration: BoxDecoration(
          color: _selectedDay == day
              ? Colors.teal.withOpacity(0.6)
              : Colors.grey[800], // Highlight selected day
          border: Border.all(color: Colors.grey.shade600),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Display the day number
            Text(
              '${day.day}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: day.month == _focusedDay.month
                    ? Colors.white
                    : Colors.grey.shade400,
              ),
            ),
            // Show the calculated number of events based on screen size
            ...events.take(maxEventsToShow).map((event) {
              DateTime startTime =
                  event.start?.dateTime?.toLocal() ?? DateTime.now();
              DateTime endTime = event.end?.dateTime?.toLocal() ??
                  startTime.add(const Duration(hours: 1));

              return SizedBox(
                width: double.infinity,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 2.0),
                  padding: const EdgeInsets.all(4.0),
                  decoration: BoxDecoration(
                    color: Colors.teal.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(5.0),
                  ),
                  child: Text(
                    '${DateFormat.jm().format(startTime)} - ${DateFormat.jm().format(endTime)}: ${event.summary ?? 'No Title'}',
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            }).toList(),
            // Display the "+X more" indicator if there are more than the max number of events
            if (events.length > maxEventsToShow)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  '+${events.length - maxEventsToShow} more...',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GoogleHttpClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleHttpClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }

  @override
  void close() {
    _client.close();
  }
}
