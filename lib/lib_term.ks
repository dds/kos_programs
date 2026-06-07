// lib_term.ks - terminal manipulations
// Copyright (c) 2015,2023 KSLib team
// Lic. MIT
// Original starting work by Github user: Dunbaratu

@lazyglobal off.
@clobberbuiltins off.

FUNCTION char_line {
  PARAMETER
    ch,
    x0, y0, x1, y1.

  LOCAL dX IS x1 - x0.
  LOCAL dY IS y1 - y0.
  LOCAL len IS SQRT(dX^2 + dY^2).
  LOCAL incSize IS 2.
  IF len > 0 {
    SET incSize TO 1 / len.
  }
  LOCAL d IS 0.
  UNTIL d > 1 {
    PRINT ch AT (d * dX + x0, d * dY + y0).
    SET d TO d + incSize.
  }
}

FUNCTION char_ellipse_arc {
  PARAMETER
    ch,
    x0, y0, xRad, yRad, deg0, deg1.

  IF deg0 > deg1 {
    LOCAL tmp IS deg0.
    SET deg0 TO deg1.
    SET deg1 TO tmp.
  }

  LOCAL longRad IS MAX(xRad, yRad).
  LOCAL incSize IS ARCSIN(1 / longRad).

  LOCAL d IS deg0.
  UNTIL d > deg1 {
    PRINT ch AT (xRad * COS(d) + x0, yRad * SIN(d) + y0).
    SET d TO d + incSize.
  }
}

FUNCTION char_circle {
  PARAMETER
    ch,
    x0, y0, rad.
  char_ellipse_arc(ch, x0, y0, rad, rad, 0, 360).
}
