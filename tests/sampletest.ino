// Get CPU cycle counter (240MHz)
uint32_t IRAM_ATTR cycles()
{
    uint32_t ccount;
    __asm__ __volatile__ ( "rsr     %0, ccount" : "=a" (ccount) );
    return ccount; 
}

void setup() {
  Serial.begin(115200);
}

#define SAMPLES 500
uint32_t t[SAMPLES];
uint32_t val[SAMPLES];

void loop() {
  int i;
  
  for(i=0; i<SAMPLES; i++)
  {
    t[i] = cycles();
    val[i] = analogRead(25);    
  }

  for(i=1; i<SAMPLES; i++)
  {
    Serial.print((t[i]-t[i-1]) / 240.0, 3); Serial.print(" "); Serial.println(val[i]);
  }
  delay(500);
}
