// AUTO-BAUD por largura de pulso no GPIO16. Detecta QUALQUER transmissao em QUALQUER baud.
#include <Arduino.h>
#define PIN_RX 16
volatile unsigned long lastEdge=0, minDelta=99999999UL, edges=0;
void IRAM_ATTR onEdge(){
  unsigned long now=micros(); unsigned long d=now-lastEdge; lastEdge=now;
  if(d>3 && d<minDelta) minDelta=d; edges++;
}
int baudDe(unsigned long us){
  const int B[]={1200,2400,4800,9600,14400,19200,38400,57600,115200};
  const int U[]={833,416,208,104,69,52,26,17,9};
  int best=0; long bestErr=1<<30;
  for(int i=0;i<9;i++){ long e=labs((long)us-U[i]); if(e<bestErr){bestErr=e;best=B[i];} }
  return best;
}
void setup(){
  Serial.begin(115200); delay(300);
  Serial.println("\n[AUTO-BAUD direto] faca o rompimento; qualquer transmissao eu detecto.");
  pinMode(PIN_RX, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_RX), onEdge, CHANGE);
}
void loop(){
  delay(1000);
  noInterrupts(); unsigned long e=edges, md=minDelta; edges=0; minDelta=99999999UL; interrupts();
  if(e>0) Serial.printf(">> bordas=%lu | pulso min=%lu us | BAUD provavel=%d\n", e, md, baudDe(md));
  else    Serial.println("...(quieto)");
}
