import 'package:flutter/material.dart';

/// App-wide route observer so screens can refresh when a route pushed on top of
/// them is popped (via [RouteAware.didPopNext]). Registered in
/// `MaterialApp.navigatorObservers`.
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
