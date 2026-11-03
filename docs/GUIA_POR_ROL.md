# Guía corta por rol

Se amplía en cada fase. Lo disponible hoy (Fase 1) está marcado con ✅.

| Rol | Dónde trabaja | Qué puede hacer hoy |
|---|---|---|
| **Gerencia** | Panel web | ✅ Ve todos los módulos. ✅ Personal, asistencia del día, usuarios y tablets, eventos rechazados. |
| **Jefe de producción** | Panel web | ✅ Asistencia del día en vivo. ✅ Lista de personal. Próximo: OP, programación, balanceo. |
| **Supervisor de módulo (confección)** | Panel web / tablet | ✅ Asistencia de su gente. Próximo: balanceo y tablero de su módulo. |
| **Bodega** | Panel web / celular | Próximo (Fase 2): rollos, insumos, kardex, conteos y etiquetas. |
| **Operario** | Tablet | ✅ Marca entrada y salida con el QR del carnet (también sin internet). Próximo (Fase 6): marcar operaciones. |
| **Satélite** | Panel web (limitado) | Próximo (Fase 6): ver sus remisiones. |
| Demás roles | Panel web | Ven en el menú sus módulos; se activan en la fase indicada (F2, F3…). |

## Tablet de entrada (asistencia)

1. El operario toca **Escanear carnet** y acerca el QR a la cámara (o digita su número: `1`, `0001` u `OPR-0001`).
2. La tablet muestra su nombre y resalta el botón sugerido (**ENTRADA** si no ha marcado hoy, **SALIDA** si ya entró).
3. Toca el botón. Aparece la confirmación verde/azul con la hora.
4. Si se equivocó, el supervisor toca **Anular** en "Últimas marcas" y escribe el motivo. La marca queda tachada, no se borra.

**Indicador arriba a la derecha:**
- `Sincronizado hh:mm` (verde): todo enviado.
- `Enviando · N pendientes` / `Sin conexión · N pendientes` (ámbar): se guardó en la tablet y se enviará solo.
- `N rechazados` (rojo): el servidor no aceptó algo; tóquelo para ver el motivo y avise al supervisor.
- Franja roja: hay registros sin enviar hace más de 8 horas, o la hora de la tablet está mal. Revise el wifi o la hora.

Nunca desinstale la app ni borre sus datos con registros pendientes: se perderían. La opción
**Desvincular tablet** no deja hacerlo mientras haya pendientes.
