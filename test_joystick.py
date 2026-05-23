import pygame
import time

pygame.init()
pygame.joystick.init()

if pygame.joystick.get_count() == 0:
    print("\nNo joystick found!")
    exit()

js = pygame.joystick.Joystick(0)
js.init()

print("\n=== Winmate GCS Joystick Test ===")
print("Move the sticks one at a time...")
print("Press Ctrl+C to exit.\n")

num_axes = js.get_numaxes()
last_values = [round(js.get_axis(i), 2) for i in range(num_axes)]

try:
    while True:
        pygame.event.pump()
        for i in range(num_axes):
            current_val = js.get_axis(i)
            if abs(current_val - last_values[i]) > 0.15:
                print(f"Axis {i} moved! Value: {current_val:.2f}")
                last_values[i] = current_val
        time.sleep(.05)
except KeyboardInterrupt:
    print("\nTest finished.")
