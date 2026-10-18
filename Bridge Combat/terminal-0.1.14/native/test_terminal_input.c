#include <assert.h>
#include "terminal_input.c"
int main(void){
 assert(!bc_terminal_policy(WM_KEYDOWN,0,0));
 assert(bc_terminal_policy(WM_INPUT,RIM_TYPEKEYBOARD,3));
 assert(bc_terminal_policy(WM_INPUT,RIM_TYPEMOUSE,3));
 assert(bc_terminal_policy(WM_KEYUP,0,3));
 assert(bc_terminal_policy(WM_LBUTTONUP,0,3));
 assert(!bc_terminal_policy(WM_PAINT,0,3));
 assert(!bc_terminal_capture(3));
 /* E was held at activation, then repeated while captured. */
 InterlockedExchange(&previous_raw['E'],1);InterlockedExchange(&previous_legacy['E'],1);
 assert(keyboard_gate('E',0,3));assert(pending_keys==1);
 assert(previous_keyboard_release(previous_raw,'E',1));assert(pending_keys==0);
 assert(previous_keyboard_release(previous_legacy,'E',1));assert(pending_keys==0);
 InterlockedExchange(&previous_mouse_raw,RI_MOUSE_LEFT_BUTTON_UP);
 assert(mouse_gate(RI_MOUSE_LEFT_BUTTON_DOWN,3));assert(pending_buttons==1);
 assert(previous_mouse_release(&previous_mouse_raw,RI_MOUSE_LEFT_BUTTON_UP));assert(pending_buttons==0);
 assert(keyboard_gate('Q',0,3));assert(keyboard_gate('Q',1,0));assert(pending_keys==0);
 bc_terminal_release();assert(!bc_terminal_captured());return 0;
}
