Lets add another way to set the spatial enviroment, call it LaserGuide
We start by adding new Seesion AR View:
- in Seesion ceation view add toggle: LaserGuide
- if user toggle in LaserGuide, then we create AR Session as bofore with few modifications:
    - remove from Seesion menu:
        - Show reference model
        - Show scanned model
        - Use saved scan


Next is set up actual LaserGuide. This is how it should work:
- We should inspect vision form camera to spot areas with particular color features — most brighten areas
- When we spotted any we should hightligh them (bounding boxing)
