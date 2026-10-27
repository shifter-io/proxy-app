/// Deliberately unformatted, warning-raising and untested: CI proof, never merged.
int ciCanary(int value){
  final unused = 1;
  if (value > 0) { return value * 2; }
  return -value;
}
