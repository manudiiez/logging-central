# Conventional Commits en este proyecto

Especificación base: https://www.conventionalcommits.org/es/v1.0.0/

## Estructura

```
tipo(scope)!: descripción corta en imperativo

Cuerpo opcional: el porqué del cambio, no el qué (el qué ya está en el diff).
Líneas de hasta ~100 caracteres.

BREAKING CHANGE: qué deja de funcionar y cómo migrar
Refs #42
```

## Tipos

| Tipo | Cuándo | Efecto en la versión |
|---|---|---|
| `feat` | Funcionalidad nueva visible para quien usa la app o la API | minor |
| `fix` | Corrige un comportamiento incorrecto | patch |
| `perf` | Mejora de rendimiento sin cambiar el comportamiento | patch |
| `refactor` | Reestructura código sin cambiar el comportamiento | — |
| `docs` | Solo documentación | — |
| `test` | Agrega o corrige tests | — |
| `build` | Dependencias, Dockerfile, empaquetado | — |
| `ci` | Workflows de GitHub Actions | — |
| `chore` | Mantenimiento que no encaja en lo anterior (configs, promociones de rama) | — |
| `style` | Formato, espacios; nada de lógica | — |
| `revert` | Revierte un commit anterior | según lo revertido |

Cualquier tipo con `!` o con `BREAKING CHANGE:` en el pie sube **major**. En `0.x` sube **minor**.

## Scopes

Son el módulo afectado, en minúscula y sin espacios. Cada repo define su lista en `CLAUDE.md`. Valores típicos:

- **API:** `properties`, `listings`, `portals`, `inmoweb`, `mercadolibre`, `images`, `auth`, `users`, `workers`, `db`, `migrations`, `config`
- **CRM:** `dashboard`, `properties`, `listings`, `leads`, `auth`, `ui`, `api-client`
- **Front:** `home`, `search`, `property-card`, `property-detail`, `seo`, `ui`, `api-client`

Para cambios transversales, se omite el scope.

## Ejemplos

Buenos:

```
feat(listings): agregar filtro por rango de precio
fix(mercadolibre): reintentar publicación cuando la API devuelve 429
perf(images): procesar miniaturas en el worker en lugar del request
refactor(portals): extraer adaptador común para Inmoweb y MercadoLibre
build(docker): usar imagen base python 3.12-slim
ci: construir imagen :testing solo si pasan los tests
chore(release): promover develop a testing
feat(api)!: cambiar el formato de precio a objeto {monto, moneda}

BREAKING CHANGE: `price` pasa de número a `{amount, currency}`. El CRM y el front deben leer `price.amount`.
```

Malos, y por qué:

| Mensaje | Problema |
|---|---|
| `arreglos varios` | No tiene tipo; "varios" indica que hay que dividir el commit |
| `fix: Arreglado el bug.` | Debe ir en imperativo, con minúscula inicial y sin punto |
| `feat(listings): agregar filtro y corregir login y actualizar deps` | Son tres commits distintos |
| `update` | No tiene tipo ni dice nada |
| `fix(Listings): …` | El scope va en minúscula |

## Commits que el hook acepta sin validar

- Mensajes que arrancan con `Merge ` (merges de promoción y back-merge)
- `Revert "…"` generados por `git revert`
- `fixup!` y `squash!`, que se usan con `git rebase -i --autosquash` antes de abrir el PR

## Squash y títulos de PR

Los PRs a `develop` se mergean con **squash**, y el repo está configurado para que el commit resultante use el **título del PR**. Por eso:

- El título del PR es lo que queda en el historial y lo que lee `next-version.sh`.
- Los commits intermedios de la rama igual se validan con el hook, pero lo que más importa es el título.
- Si el PR mezcla un `feat` y un `fix`, el título lleva el tipo de mayor impacto (`feat`).
