# Prefer const border radius

## Rule id

prefer-const-border-radius

## Description

BorderRadius.circular constructor calls const BorderRadius.all constructor under the hood. This rule allows to replace
BorderRadius.circular(radius) with const BorderRadius.all(Radius.circular(radius)) if radius is a constant value.

### Example

Bad:

```dart
final _defaultFinalRadius = BorderRadius.circular(8); // LINT

class RoundedWidget extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const RoundedWidget({
    Key? key,
    this.borderRadius = _defaultRadius,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: child,
    );
  }
}
```

Good:

```dart
const _defaultRadius = BorderRadius.all(Radius.circular(8));

class RoundedWidget extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const RoundedWidget({
    Key? key,
    this.borderRadius = _defaultRadius,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: child,
    );
  }
}
```