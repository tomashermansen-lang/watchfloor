import os


def greet(name):
    x = os.getenv( "GREETING" )
    return f"{x} {name}"
