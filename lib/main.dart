import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// NOTA DE SEGURIDAD: la API Key de Google Maps NO aparece en este archivo.
// Se inyecta en tiempo de compilación desde android/local.properties
// (ignorado por Git) hacia AndroidManifest.xml mediante manifestPlaceholders.

// ---------------------------------------------------------------------------
// Paleta
// ---------------------------------------------------------------------------
class _Paleta {
  static const Color tinta = Color(0xFF12202B); // texto principal / pill
  static const Color laguna = Color(0xFF1F8A8A); // "tú"
  static const Color citrico = Color(0xFFFF8A2B); // destino
  static const Color bruma = Color(0xFFEEF3F6); // fondos suaves
  static const Color gris = Color(0xFF6B7C88); // texto secundario
}

void main() {
  runApp(const LocalizadorPoiApp());
}

class LocalizadorPoiApp extends StatelessWidget {
  const LocalizadorPoiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Localizador de POI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _Paleta.laguna,
          primary: _Paleta.laguna,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: _Paleta.bruma,
      ),
      home: const MapaPage(),
    );
  }
}

class MapaPage extends StatefulWidget {
  const MapaPage({super.key});

  @override
  State<MapaPage> createState() => _MapaPageState();
}

class _MapaPageState extends State<MapaPage> {
  // Posición inicial de respaldo: UTXJ.
  static const LatLng _utxj = LatLng(20.2756, -97.9611);
  static const double _zoomInicial = 15.5;
  static const MarkerId _idDestino = MarkerId('destino');

  GoogleMapController? _mapController;
  StreamSubscription<Position>? _posicionSub;

  Position? _miPosicion;
  LatLng? _destino;
  final Set<Marker> _marcadores = <Marker>{};

  double? _distanciaMetros;
  String _calle = '—';
  String _colonia = '—';
  String _localidad = '—';

  bool _cargando = true;
  bool _permisoConcedido = false;
  bool _geocodificando = false;
  bool _expandido = true;
  String? _error;

  // Evita que una geocodificación lenta pise el resultado de un toque más nuevo.
  int _tokenGeocodificacion = 0;

  @override
  void initState() {
    super.initState();
    _iniciarUbicacion();
  }

  @override
  void dispose() {
    _tokenGeocodificacion++;
    _posicionSub?.cancel();
    _posicionSub = null;
    _mapController?.dispose();
    _mapController = null;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Ubicación en tiempo real
  // ---------------------------------------------------------------------------

  Future<Position> _obtenerUbicacion() async {
    final bool activo = await Geolocator.isLocationServiceEnabled();
    if (!activo) {
      return Future.error('GPS desactivado. Actívalo e inténtalo de nuevo.');
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) {
        return Future.error('Permiso de ubicación denegado.');
      }
    }
    if (perm == LocationPermission.deniedForever) {
      return Future.error(
        'Permiso de ubicación denegado permanentemente. '
        'Habilítalo desde los ajustes de la app.',
      );
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
  }

  Future<void> _iniciarUbicacion() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _error = null;
      });
    }
    try {
      final Position pos = await _obtenerUbicacion();
      if (!mounted) return;
      setState(() {
        _miPosicion = pos;
        _permisoConcedido = true;
        _cargando = false;
        _recalcularDistancia();
      });
      await _centrarEnUsuario();
      _suscribirseAUbicacion();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = e is String ? e : 'No se pudo obtener la ubicación: $e';
      });
    }
  }

  void _suscribirseAUbicacion() {
    _posicionSub?.cancel();
    _posicionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(
      (Position pos) {
        if (!mounted) return;
        setState(() {
          _miPosicion = pos;
          _recalcularDistancia();
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = 'Error en el flujo de ubicación: $e');
      },
    );
  }

  Future<void> _centrarEnUsuario() async {
    final Position? pos = _miPosicion;
    final GoogleMapController? ctrl = _mapController;
    if (pos == null || ctrl == null) return;
    await ctrl.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 17),
    );
  }

  // ---------------------------------------------------------------------------
  // Marcadores dinámicos
  // ---------------------------------------------------------------------------

  Marker _construirMarcador(LatLng punto, String snippet) {
    return Marker(
      markerId: _idDestino,
      position: punto,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      infoWindow: InfoWindow(title: 'Destino', snippet: snippet),
    );
  }

  void _agregarMarcador(LatLng punto) {
    setState(() {
      _destino = punto;
      _marcadores
        ..removeWhere((m) => m.markerId == _idDestino)
        ..add(_construirMarcador(
          punto,
          '${punto.latitude.toStringAsFixed(5)}, '
          '${punto.longitude.toStringAsFixed(5)}',
        ));
      _calle = '—';
      _colonia = '—';
      _localidad = '—';
      _expandido = true;
      _recalcularDistancia();
    });
    _geocodificarDestino(punto);
  }

  void _limpiarDestino() {
    _tokenGeocodificacion++;
    setState(() {
      _destino = null;
      _marcadores.clear();
      _distanciaMetros = null;
      _geocodificando = false;
      _calle = '—';
      _colonia = '—';
      _localidad = '—';
    });
  }

  // ---------------------------------------------------------------------------
  // Distancia y geocodificación inversa
  // ---------------------------------------------------------------------------

  void _recalcularDistancia() {
    final Position? pos = _miPosicion;
    final LatLng? dest = _destino;
    if (pos == null || dest == null) {
      _distanciaMetros = null;
      return;
    }
    _distanciaMetros = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      dest.latitude,
      dest.longitude,
    );
  }

  String? _primerValido(List<String?> candidatos) {
    for (final String? c in candidatos) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return null;
  }

  Future<void> _geocodificarDestino(LatLng punto) async {
    final int token = ++_tokenGeocodificacion;
    setState(() => _geocodificando = true);
    try {
      final List<Placemark> lugares =
          await placemarkFromCoordinates(punto.latitude, punto.longitude);
      if (!mounted || token != _tokenGeocodificacion) return;

      final Placemark? p = lugares.isNotEmpty ? lugares.first : null;
      final String calle =
          _primerValido([p?.street, p?.thoroughfare]) ?? 'Sin calle disponible';
      final String colonia =
          _primerValido([p?.subLocality]) ?? 'Sin colonia disponible';
      final String localidad = _primerValido([
            p?.locality,
            p?.subAdministrativeArea,
            p?.administrativeArea,
          ]) ??
          'Sin localidad disponible';

      setState(() {
        _calle = calle;
        _colonia = colonia;
        _localidad = localidad;
        _geocodificando = false;
        _marcadores
          ..removeWhere((m) => m.markerId == _idDestino)
          ..add(_construirMarcador(punto, '$calle · $colonia'));
      });
    } catch (e) {
      if (!mounted || token != _tokenGeocodificacion) return;
      setState(() {
        _calle = 'No se pudo obtener la dirección';
        _colonia = '—';
        _localidad = '—';
        _geocodificando = false;
      });
    }
  }

  /// Devuelve (valor, unidad): 320 m → ('320', 'm'); 1530 m → ('1.53', 'km').
  (String, String) _partesDistancia(double metros) {
    if (metros >= 1000) {
      return ((metros / 1000).toStringAsFixed(2), 'km');
    }
    return (metros.toStringAsFixed(0), 'm');
  }

  String _coords(double lat, double lng) =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: _utxj,
              zoom: _zoomInicial,
            ),
            myLocationEnabled: _permisoConcedido,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            padding: EdgeInsets.only(bottom: _expandido ? 340 : 150),
            markers: _marcadores,
            onMapCreated: (GoogleMapController ctrl) {
              _mapController = ctrl;
              _centrarEnUsuario();
            },
            onTap: (LatLng punto) => _agregarMarcador(punto),
          ),
          _barraSuperior(context),
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 12),
                  child: Material(
                    color: _Paleta.tinta,
                    shape: const CircleBorder(),
                    elevation: 6,
                    shadowColor: Colors.black45,
                    child: IconButton(
                      tooltip: 'Centrar en mi ubicación',
                      iconSize: 26,
                      padding: const EdgeInsets.all(14),
                      color: Colors.white,
                      icon: const Icon(Icons.my_location),
                      onPressed: _miPosicion == null
                          ? _iniciarUbicacion
                          : _centrarEnUsuario,
                    ),
                  ),
                ),
                _hoja(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Pastilla flotante superior: título, estado y acción de quitar destino.
  Widget _barraSuperior(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 52,
              padding: const EdgeInsets.only(left: 6, right: 6),
              decoration: BoxDecoration(
                color: _Paleta.tinta,
                borderRadius: BorderRadius.circular(26),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: _Paleta.laguna,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.explore, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Localizador de POI',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  if (_cargando)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (_destino != null)
                    IconButton(
                      tooltip: 'Quitar destino',
                      color: Colors.white,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _limpiarDestino,
                    ),
                ],
              ),
            ),
            if (_error != null) _bannerError(context),
          ],
        ),
      ),
    );
  }

  Widget _bannerError(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_off_rounded,
                      color: _Paleta.citrico, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: _Paleta.tinta,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: _iniciarUbicacion,
                    child: const Text('Reintentar'),
                  ),
                  TextButton(
                    onPressed: Geolocator.openLocationSettings,
                    child: const Text('Ajustes de GPS'),
                  ),
                  TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: const Text('Permisos'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Hoja inferior: distancia grande + ruta + dirección.
  Widget _hoja(BuildContext context) {
    final Position? pos = _miPosicion;
    final bool hayDestino = _destino != null;

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Asa para plegar / desplegar
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _expandido = !_expandido),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD3DCE2),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
                _cabeceraDistancia(context, hayDestino),
                if (_expandido) ...[
                  const SizedBox(height: 18),
                  _rutaVisual(pos),
                  if (hayDestino) ...[
                    const SizedBox(height: 16),
                    if (_geocodificando)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: const LinearProgressIndicator(
                          minHeight: 4,
                          color: _Paleta.citrico,
                          backgroundColor: _Paleta.bruma,
                        ),
                      )
                    else
                      _datosDireccion(),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cabeceraDistancia(BuildContext context, bool hayDestino) {
    if (!hayDestino || _distanciaMetros == null) {
      return Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _Paleta.citrico.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.touch_app_rounded, color: _Paleta.citrico),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Text(
              'Toca el mapa para elegir un destino',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _Paleta.tinta,
              ),
            ),
          ),
        ],
      );
    }

    final (String valor, String unidad) = _partesDistancia(_distanciaMetros!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          valor,
          style: const TextStyle(
            fontSize: 46,
            height: 1,
            fontWeight: FontWeight.w800,
            color: _Paleta.tinta,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(
            unidad,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: _Paleta.gris,
            ),
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'hasta tu destino',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: _Paleta.gris),
          ),
        ),
      ],
    );
  }

  // Línea de tiempo vertical: Tú → Destino.
  Widget _rutaVisual(Position? pos) {
    final String miTxt =
        pos == null ? 'Sin datos' : _coords(pos.latitude, pos.longitude);
    final String destTxt = _destino == null
        ? 'Aún sin destino'
        : _coords(_destino!.latitude, _destino!.longitude);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              const SizedBox(height: 4),
              _punto(_Paleta.laguna),
              Expanded(
                child: Container(
                  width: 2,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: const Color(0xFFD3DCE2),
                ),
              ),
              _punto(_Paleta.citrico),
              const SizedBox(height: 4),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _lineaRuta('Tu ubicación', miTxt),
                const SizedBox(height: 14),
                _lineaRuta('Destino', destTxt),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _punto(Color c) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: c, width: 4),
        ),
      );

  Widget _lineaRuta(String titulo, String valor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titulo,
          style: const TextStyle(fontSize: 12.5, color: _Paleta.gris),
        ),
        const SizedBox(height: 2),
        Text(
          valor,
          style: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
            color: _Paleta.tinta,
          ),
        ),
      ],
    );
  }

  Widget _datosDireccion() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _Paleta.bruma,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          _Fila(icono: Icons.signpost_rounded, etiqueta: 'Calle', valor: _calle),
          _Fila(
            icono: Icons.holiday_village_rounded,
            etiqueta: 'Colonia',
            valor: _colonia,
          ),
          _Fila(
            icono: Icons.location_city_rounded,
            etiqueta: 'Localidad',
            valor: _localidad,
          ),
        ],
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  const _Fila({
    required this.icono,
    required this.etiqueta,
    required this.valor,
  });

  final IconData icono;
  final String etiqueta;
  final String valor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 20, color: _Paleta.laguna),
          const SizedBox(width: 10),
          SizedBox(
            width: 78,
            child: Text(
              etiqueta,
              style: const TextStyle(color: _Paleta.gris, fontSize: 14),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              style: const TextStyle(
                color: _Paleta.tinta,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}