# Localizador de Puntos de Interés (Flutter)

Práctica guiada · Desarrollo Móvil Integral · Semana 10 · UTXJ IDGS 10°

GPS en tiempo real (`distanceFilter: 10`), marcadores al tocar el mapa, distancia en metros
y geocodificación inversa (calle / colonia).

## Seguridad de la API Key
- La clave vive solo en `android/local.properties` (`maps.apikey=...`), que está en `.gitignore`.
- `android/app/build.gradle.kts` la lee y la inyecta con `manifestPlaceholders["MAPS_API_KEY"]`.
- `AndroidManifest.xml` la consume como `${MAPS_API_KEY}`. No aparece en código Dart.
- En Google Cloud restringe la clave a **Android apps** con paquete `com.utxj.localizador_poi` y tu huella SHA-1.

## Ejecutar
```powershell
flutter create . --org com.utxj --project-name localizador_poi --platforms=android
flutter pub get
# agrega tu clave en android\local.properties  ->  maps.apikey=AIza...
flutter run
```
