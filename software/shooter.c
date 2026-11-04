#include <stdint.h>
#define MMIO(a) (*(volatile uint32_t *)(a))
#define KEYS MMIO(0x10000008u)
#define LED MMIO(0x10000000u)
#define UART MMIO(0x10000004u)
#define CYCLES MMIO(0x10000010u)
#define INSTRET MMIO(0x10000018u)
#define FRAME MMIO(0x10000044u)
#define COMMIT MMIO(0x10000050u)
#define HUD ((volatile uint32_t *)0x10000030u)
#define SPRITES ((volatile uint32_t *)0x10000100u)
typedef struct { int x,y,vx,vy,alive; } Actor;
static Actor player, enemies[3], bullets[8];
static int lives,score,level,state,facing,grounded,cooldown,invincible;
static void puts_uart(const char *s) { while(*s) { while(!(UART&1u)) {} UART=(uint8_t)*s++; } }
static uint32_t bcd(int value) {
    uint32_t out=0; const int power[4]={1000,100,10,1};
    for(int i=0;i<4;i++) { uint32_t n=0; while(value>=power[i]) { value-=power[i]; n++; } out=(out<<4)|n; }
    return out;
}
static int overlap(int ax,int ay,int aw,int ah,int bx,int by,int bw,int bh) {
    return ax<bx+bw && ax+aw>bx && ay<by+bh && ay+ah>by;
}
static void new_level(void) {
    player=(Actor){32,404,0,0,1}; grounded=1; facing=1; cooldown=0; invincible=0;
    for(int i=0;i<3;i++) enemies[i]=(Actor){300+(i<<6),408,(i&1)?1:-1,0,1};
    for(int i=0;i<8;i++) bullets[i].alive=0;
}
static void sprite(int i,int x,int y,int w,int h,int type,int enabled) {
    SPRITES[i<<1]=enabled ? 0x80000000u|((uint32_t)type<<28)|((uint32_t)y<<16)|(uint32_t)x : 0;
    SPRITES[(i<<1)+1]=(uint32_t)w|((uint32_t)h<<8);
}
static void render(void) {
    sprite(0,player.x,player.y,20,28,1,state==1 && !(invincible&4));
    for(int i=0;i<3;i++) sprite(i+1,enemies[i].x,enemies[i].y,24,24,2,state==1 && enemies[i].alive);
    for(int i=0;i<8;i++) sprite(i+4,bullets[i].x,bullets[i].y,8,4,3,state==1 && bullets[i].alive);
    int left=enemies[0].alive+enemies[1].alive+enemies[2].alive;
    sprite(12,608,380,24,52,0,state==1 && !left);
    for(int i=13;i<16;i++) sprite(i,0,0,0,0,0,0);
    HUD[0]=(uint32_t)state|((uint32_t)lives<<8)|((uint32_t)level<<16)|((uint32_t)left<<24);
    HUD[1]=bcd(score);
}
static void tick(uint32_t keys,uint32_t pressed) {
    if(state!=1) {
        if(pressed) { state=1;lives=3;score=0;level=1;new_level();puts_uart("SHOOTER START\r\n"); }
        return;
    }
    if(cooldown) cooldown--;
    if(invincible) invincible--;
    player.vx=0;
    if((keys&3u)==1u) { player.vx=-4;facing=-1; }
    if((keys&3u)==2u) { player.vx=4;facing=1; }
    if((pressed&4u) && grounded) {player.vy=-15;grounded=0;}
    player.x+=player.vx;if(player.x<0)player.x=0;if(player.x>620)player.x=620;
    int old_bottom=player.y+28;
    player.vy++;if(player.vy>12)player.vy=12;
    player.y+=player.vy;grounded=0;
    const int px[4]={0,96,288,448}, py[4]={432,352,272,336}, pw[4]={640,128,128,128};
    for(int p=0;p<4;p++) if(player.vy>=0 && old_bottom<=py[p] && player.y+28>=py[p] && player.x+20>px[p] && player.x<px[p]+pw[p]) {
        player.y=py[p]-28;player.vy=0;grounded=1;
    }
    if((keys&8u) && !cooldown) {
        for(int i=0;i<8;i++) if(!bullets[i].alive) {
            bullets[i]=(Actor){player.x+(facing>0?20:-8),player.y+12,facing>0?8:-8,0,1};cooldown=6;break;
        }
    }
    for(int i=0;i<8;i++) if(bullets[i].alive) {
        bullets[i].x+=bullets[i].vx;
        if(bullets[i].x<0 || bullets[i].x>632) {bullets[i].alive=0;continue;}
        for(int e=0;e<3;e++) if(enemies[e].alive && overlap(bullets[i].x,bullets[i].y,8,4,enemies[e].x,enemies[e].y,24,24)) {
            enemies[e].alive=0;bullets[i].alive=0;score+=10;puts_uart("HIT +10\r\n");break;
        }
    }
    for(int i=0;i<3;i++) if(enemies[i].alive) {
        enemies[i].x+=enemies[i].vx;
        if(enemies[i].x<250)enemies[i].vx=1;
        if(enemies[i].x>580)enemies[i].vx=-1;
        if(!invincible && overlap(player.x,player.y,20,28,enemies[i].x,enemies[i].y,24,24)) {
            lives--;invincible=60;player.x=32;player.y=404;player.vy=0;puts_uart("DAMAGE\r\n");
            if(!lives) {state=3;puts_uart("GAME OVER\r\n");}
        }
    }
    if(state==1 && !enemies[0].alive && !enemies[1].alive && !enemies[2].alive && player.x>=600) {
        if(level==3) {state=2;puts_uart("SHOOTER WIN\r\n");}
        else {level++;new_level();puts_uart("NEXT LEVEL\r\n");}
    }
    LED=(uint32_t)lives;
}
int main(void) {
    uint32_t last=FRAME,previous=0;
    state=0;lives=3;score=0;level=1;new_level();
    puts_uart("RV32I SHOOTER READY 800x480 KEY0 LEFT KEY1 RIGHT KEY2 JUMP KEY3 FIRE\r\n");
    for(;;) {
        uint32_t now=FRAME;
        if(now==last)continue;
        last=now;
        uint32_t start=CYCLES, retired=INSTRET;
        uint32_t keys=(~KEYS)&15u;
        tick(keys,keys&~previous);previous=keys;
        render();
        HUD[2]=CYCLES-start;HUD[3]=INSTRET-retired;
        COMMIT=1;
    }
}
