import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const String googleMapsApiKey = 'YOUR_GOOGLE_MAPS_API_KEY_HERE';

  late GoogleMapController mapController;
  LatLng? currentLocation;
  Set<Marker> markers = {};
  Set<Polyline> polylines = {};
  String? distanceText;
  String? durationText;

  final TextEditingController destinationController = TextEditingController();

  bool isLoading = false;
  String? errorMessage;
  String currentAddress = "Fetching location...";

  // Marker IDs for start and destination
  final MarkerId startMarkerId = const MarkerId('start_location');
  final MarkerId destinationMarkerId = const MarkerId('destination_location');

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();

        if (permission == LocationPermission.denied) {
          _showPermissionDeniedDialog();
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showPermissionPermanentlyDeniedDialog();
        return;
      }

      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Get address from coordinates
      final address = await _getAddressFromLatLng(
        position.latitude,
        position.longitude,
      );

      setState(() {
        currentLocation = LatLng(position.latitude, position.longitude);
        currentAddress = address;
        isLoading = false;

        // Add current location marker
        _addCurrentLocationMarker();
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Error getting location: $e';
        isLoading = false;
      });
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Permission Required'),
          content: const Text(
            'This app needs location permission to show your current location and calculate routes.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _getCurrentLocation();
              },
              child: const Text('Try Again'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }

  void _showPermissionPermanentlyDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Permission Required'),
          content: const Text(
            'Location permissions are permanently denied. Please enable them in app settings to use this feature.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openAppSettings() async {
    final Uri url = Uri.parse('app-settings:');
    try {
      await launchUrl(url);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open app settings')),
        );
      }
    }
  }

  Future<String> _getAddressFromLatLng(
    double latitude,
    double longitude,
  ) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json?latlng=$latitude,$longitude&key=$googleMapsApiKey',
      );

      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          return data['results'][0]['formatted_address'];
        }
      }
      return 'Unknown Location';
    } catch (e) {
      return 'Unknown Location';
    }
  }

  void _addCurrentLocationMarker() {
    if (currentLocation != null) {
      markers.add(
        Marker(
          markerId: startMarkerId,
          position: currentLocation!,
          infoWindow: InfoWindow(
            title: 'Current Location',
            snippet: currentAddress,
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      );
    }
  }

  void _addDestinationMarker(LatLng position, String address) {
    markers.add(
      Marker(
        markerId: destinationMarkerId,
        position: position,
        infoWindow: InfoWindow(title: 'Destination', snippet: address),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ),
    );
  }

  void _onMapCreated(GoogleMapController controller) {
    mapController = controller;
  }

  void _onMapTapped(LatLng location) {
    setState(() {
      markers.add(
        Marker(
          markerId: MarkerId('marker_${markers.length}'),
          position: location,
          infoWindow: InfoWindow(
            title: 'Marker ${markers.length}',
            snippet:
                '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
          ),
        ),
      );
    });
  }

  Future<void> _calculateRoute() async {
    if (destinationController.text.isEmpty) {
      setState(() {
        errorMessage = 'Please enter destination address';
      });
      return;
    }

    if (currentLocation == null) {
      setState(() {
        errorMessage = 'Current location not available';
      });
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
      polylines.clear();
      distanceText = null;
      durationText = null;

      // Clear previous destination marker but keep current location marker
      markers.removeWhere((marker) => marker.markerId == destinationMarkerId);
    });

    try {
      LatLng destLocation;

      // Geocode destination address
      final destLoc = await _geocodeAddress(destinationController.text);
      if (destLoc == null) {
        setState(() {
          errorMessage = 'Could not find destination address';
          isLoading = false;
        });
        return;
      }
      destLocation = destLoc;

      // Add destination marker
      _addDestinationMarker(destLocation, destinationController.text);

      // Get directions
      final directions = await _getDirections(currentLocation!, destLocation);

      if (directions != null) {
        setState(() {
          polylines.add(
            Polyline(
              polylineId: const PolylineId('route'),
              color: Colors.blue,
              width: 5,
              points: directions['polyline_points'],
            ),
          );
          distanceText = directions['distance'];
          durationText = directions['duration'];
        });

        // Fit map to show both points and route
        final bounds = _getBounds(directions['polyline_points']);
        mapController.animateCamera(CameraUpdate.newLatLngBounds(bounds, 100));
      }
    } catch (e) {
      setState(() {
        errorMessage = 'Error calculating route: $e';
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<LatLng?> _geocodeAddress(String address) async {
    final encodedAddress = Uri.encodeComponent(address);
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?address=$encodedAddress&key=$googleMapsApiKey',
    );

    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['status'] == 'OK' && data['results'].isNotEmpty) {
        final location = data['results'][0]['geometry']['location'];
        return LatLng(location['lat'], location['lng']);
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getDirections(LatLng start, LatLng end) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json?'
      'origin=${start.latitude},${start.longitude}&'
      'destination=${end.latitude},${end.longitude}&'
      'key=$googleMapsApiKey',
    );

    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['status'] == 'OK') {
        final route = data['routes'][0];
        final leg = route['legs'][0];

        // Decode polyline points
        final points = _decodePolyline(route['overview_polyline']['points']);

        return {
          'distance': leg['distance']['text'],
          'duration': leg['duration']['text'],
          'polyline_points': points,
        };
      }
    }
    return null;
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  LatLngBounds _getBounds(List<LatLng> points) {
    double? west, north, east, south;

    for (LatLng point in points) {
      west = west != null
          ? (point.longitude < west ? point.longitude : west)
          : point.longitude;
      north = north != null
          ? (point.latitude > north ? point.latitude : north)
          : point.latitude;
      east = east != null
          ? (point.longitude > east ? point.longitude : east)
          : point.longitude;
      south = south != null
          ? (point.latitude < south ? point.latitude : south)
          : point.latitude;
    }

    return LatLngBounds(
      southwest: LatLng(south!, west!),
      northeast: LatLng(north!, east!),
    );
  }

  void _clearMarkers() {
    setState(() {
      markers.clear();
      polylines.clear();
      distanceText = null;
      durationText = null;
      destinationController.clear();

      // Re-add current location marker after clearing
      if (currentLocation != null) {
        _addCurrentLocationMarker();
      }
    });
  }

  void _centerOnMyLocation() {
    if (currentLocation != null) {
      mapController.animateCamera(
        CameraUpdate.newLatLngZoom(currentLocation!, 15),
      );
    }
  }

  void _refreshLocation() {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });
    _getCurrentLocation();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Maps App'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshLocation,
            tooltip: 'Refresh Location',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _clearMarkers,
            tooltip: 'Clear Markers',
          ),
        ],
      ),
      body: Column(
        children: [
          // Current Location Display
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue),
              ),
              child: Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Current Location',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.blue,
                          ),
                        ),
                        Text(
                          currentAddress,
                          style: const TextStyle(fontSize: 14),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Destination Input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              children: [
                TextField(
                  controller: destinationController,
                  decoration: const InputDecoration(
                    labelText: 'Destination Address',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.flag),
                    hintText: 'Enter your destination address',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: isLoading ? null : _calculateRoute,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : const Text('Calculate Route'),
                      ),
                    ),
                  ],
                ),
                if (distanceText != null && durationText != null) ...[
                  const SizedBox(height: 10),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          Column(
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.directions_car, size: 16),
                                  SizedBox(width: 4),
                                  Text(
                                    'Distance',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              Text(distanceText!),
                            ],
                          ),
                          Column(
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.access_time, size: 16),
                                  SizedBox(width: 4),
                                  Text(
                                    'Duration',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              Text(durationText!),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Error message
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Map
          Expanded(
            child: currentLocation == null
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Getting your location...'),
                      ],
                    ),
                  )
                : GoogleMap(
                    onMapCreated: _onMapCreated,
                    initialCameraPosition: CameraPosition(
                      target: currentLocation!,
                      zoom: 15,
                    ),
                    markers: markers,
                    polylines: polylines,
                    onTap: _onMapTapped,
                    myLocationEnabled: true,
                    myLocationButtonEnabled: false,
                    compassEnabled: true,
                  ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: _centerOnMyLocation,
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
            mini: true,
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 10),
          if (markers.length > 1)
            FloatingActionButton(
              onPressed: () {
                // Fit map to show all markers
                final bounds = _getAllMarkersBounds();
                mapController.animateCamera(
                  CameraUpdate.newLatLngBounds(bounds, 100),
                );
              },
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              mini: true,
              child: const Icon(Icons.zoom_out_map),
            ),
        ],
      ),
    );
  }

  LatLngBounds _getAllMarkersBounds() {
    if (markers.isEmpty) {
      return LatLngBounds(
        southwest: const LatLng(0, 0),
        northeast: const LatLng(0, 0),
      );
    }

    double? west, north, east, south;

    for (Marker marker in markers) {
      final position = marker.position;
      west = west != null
          ? (position.longitude < west ? position.longitude : west)
          : position.longitude;
      north = north != null
          ? (position.latitude > north ? position.latitude : north)
          : position.latitude;
      east = east != null
          ? (position.longitude > east ? position.longitude : east)
          : position.longitude;
      south = south != null
          ? (position.latitude < south ? position.latitude : south)
          : position.latitude;
    }

    return LatLngBounds(
      southwest: LatLng(south!, west!),
      northeast: LatLng(north!, east!),
    );
  }

  @override
  void dispose() {
    destinationController.dispose();
    super.dispose();
  }
}
