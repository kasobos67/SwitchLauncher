#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bake HOME blank materials into a small, transparent two-palette atlas.

The supplied HOME resources define P_Blank at 256 square on a 270-pixel pitch,
White1x1A64 with material alpha 140, a 3-pixel border and a centered 5-pixel
knockout shadow. ColourTable slot 31 is 0x505050 / white in the two palettes.
This translates those material parameters for the host renderer; it does not
execute Nintendo's proprietary shader. No firmware or keys are needed to bake.
"""
from pathlib import Path
import math
import struct

SIZE=256
PAD=8
CELL=SIZE+2*PAD
FILL_ALPHA=(64/255)*(140/255)
BORDER_ALPHA=140/255


def smooth(a,b,x):
    t=max(0,min(1,(x-a)/(b-a)))
    return t*t*(3-2*t)


def over(dst,rgb,alpha):
    a=alpha+dst[3]*(1-alpha)
    return tuple((rgb[i]*alpha+dst[i]*dst[3]*(1-alpha))/a if a else 0 for i in range(3))+(a,)


def pixels():
    # Shared firmware colour table: basic black / basic white.
    for y in range(CELL):
        for white in (False,True):
            tint=(255,255,255) if white else (80,80,80)
            shadow=(90,30,20) if white else (0,0,0)
            shadow_alpha=60/255 if white else 1
            for x in range(CELL):
                xx=x-PAD+.5;yy=y-PAD+.5
                dx=abs(xx-SIZE/2)-SIZE/2;dy=abs(yy-SIZE/2)-SIZE/2
                d=math.hypot(max(dx,0),max(dy,0))+min(max(dx,dy),0)
                coverage=1-smooth(-.5,.5,d)
                rgba=over((0,0,0,0),shadow,FILL_ALPHA*shadow_alpha*(1-smooth(-5,5,d))*(1-coverage))
                rgba=over(rgba,tint,FILL_ALPHA*coverage)
                rim=coverage*(1-smooth(2,3,-d))
                rgba=over(rgba,tint,BORDER_ALPHA*rim)
                r,g,b=(round(c) for c in rgba[:3]);a=round(rgba[3]*255)
                yield b,g,r,a


def build(destination=None):
    destination=destination or Path(__file__).resolve().parents[1]/'assets/home-blank.tga'
    header=struct.pack('<BBBHHBHHHHBB',0,0,2,0,0,0,0,0,CELL*2,CELL,32,0x28)
    destination.write_bytes(header+b''.join(bytes(p) for p in pixels()))
    return destination


if __name__=='__main__':
    print(build())
