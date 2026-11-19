import 'package:flutter_test/flutter_test.dart';

void main() {
  // Prueba mínima de humo: el mapa nativo y el GPS requieren un dispositivo
  // real, por lo que la validación funcional se hace en el teléfono.
  test('el entorno de pruebas funciona', () {
    expect(1 + 1, 2);
  });
}
