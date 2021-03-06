/*
 Copyright (c) 2016, OpenEmu Team


 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "mednafen.h"
#include "settings-driver.h"
#include "state-driver.h"
#include "mednafen-driver.h"
#include "MemoryStream.h"

#import "MednafenGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>
#import "OELynxSystemResponderClient.h"
#import "OENGPSystemResponderClient.h"
#import "OEPCESystemResponderClient.h"
#import "OEPCECDSystemResponderClient.h"
#import "OEPCFXSystemResponderClient.h"
#import "OEPSXSystemResponderClient.h"
#import "OESaturnSystemResponderClient.h"
#import "OEVBSystemResponderClient.h"
#import "OEWSSystemResponderClient.h"

static MDFNGI *game;
static MDFN_Surface *surf;

namespace MDFN_IEN_VB
{
    extern void VIP_SetParallaxDisable(bool disabled);
    extern void VIP_SetAnaglyphColors(uint32 lcolor, uint32 rcolor);
    int mednafenCurrentDisplayMode = 1;
}

enum systemTypes{ lynx, ngp, pce, pcfx, psx, ss, vb, wswan };

@interface MednafenGameCore () <OELynxSystemResponderClient, OENGPSystemResponderClient, OEPCESystemResponderClient, OEPCECDSystemResponderClient, OEPCFXSystemResponderClient, OEPSXSystemResponderClient, OESaturnSystemResponderClient, OEVBSystemResponderClient, OEWSSystemResponderClient>
{
    uint32_t *_inputBuffer[8];
    int _systemType;
    int _videoWidth, _videoHeight;
    int _videoOffsetX, _videoOffsetY;
    int _multiTapPlayerCount;
    double _sampleRate;
    double _masterClock;

    NSString *_mednafenCoreModule;
    NSTimeInterval _mednafenCoreTiming;
    OEIntSize _mednafenCoreAspect;
    NSUInteger _maxDiscs;
    NSUInteger _multiDiscTotal;
    BOOL _isSBIRequired;
    BOOL _isMultiDiscGame;
    NSMutableArray *_allCueSheetFiles;
}

@end

static __weak MednafenGameCore *_current;

@implementation MednafenGameCore

static void mednafen_init()
{
    GET_CURRENT_OR_RETURN();

    MDFNI_InitializeModules();

    std::vector<MDFNSetting> settings;

    NSString *batterySavesDirectory = current.batterySavesDirectoryPath;
    NSString *biosPath = current.biosDirectoryPath;

    MDFNI_Initialize([biosPath UTF8String], settings);

    // Set bios/system file and memcard save paths
    MDFNI_SetSetting("pce.cdbios", [[[biosPath stringByAppendingPathComponent:@"syscard3"] stringByAppendingPathExtension:@"pce"] UTF8String]); // PCE CD BIOS
    MDFNI_SetSetting("pcfx.bios", [[[biosPath stringByAppendingPathComponent:@"pcfx"] stringByAppendingPathExtension:@"rom"] UTF8String]); // PCFX BIOS
    MDFNI_SetSetting("psx.bios_jp", [[[biosPath stringByAppendingPathComponent:@"scph5500"] stringByAppendingPathExtension:@"bin"] UTF8String]); // JP SCPH-5500 BIOS
    MDFNI_SetSetting("psx.bios_na", [[[biosPath stringByAppendingPathComponent:@"scph5501"] stringByAppendingPathExtension:@"bin"] UTF8String]); // NA SCPH-5501 BIOS
    MDFNI_SetSetting("psx.bios_eu", [[[biosPath stringByAppendingPathComponent:@"scph5502"] stringByAppendingPathExtension:@"bin"] UTF8String]); // EU SCPH-5502 BIOS
    MDFNI_SetSetting("ss.bios_jp", [[[biosPath stringByAppendingPathComponent:@"sega_101"] stringByAppendingPathExtension:@"bin"] UTF8String]); // JP SS BIOS
    MDFNI_SetSetting("ss.bios_na_eu", [[[biosPath stringByAppendingPathComponent:@"mpr-17933"] stringByAppendingPathExtension:@"bin"] UTF8String]); // NA/EU SS BIOS
    MDFNI_SetSetting("filesys.path_sav", [batterySavesDirectory UTF8String]); // Memcards

    // VB defaults. dox http://mednafen.sourceforge.net/documentation/09x/vb.html
    MDFNI_SetSetting("vb.disable_parallax", "1");       // Disable parallax for BG and OBJ rendering
    MDFNI_SetSetting("vb.anaglyph.preset", "disabled"); // Disable anaglyph preset
    MDFNI_SetSetting("vb.anaglyph.lcolor", "0xFF0000"); // Anaglyph l color
    MDFNI_SetSetting("vb.anaglyph.rcolor", "0x000000"); // Anaglyph r color
    //MDFNI_SetSetting("vb.allow_draw_skip", "1");      // Allow draw skipping
    //MDFNI_SetSetting("vb.instant_display_hack", "1"); // Display latency reduction hack

    MDFNI_SetSetting("pce.slstart", "0"); // PCE: First rendered scanline
    MDFNI_SetSetting("pce.slend", "239"); // PCE: Last rendered scanline

    MDFNI_SetSetting("psx.h_overscan", "0"); // Remove PSX overscan

    // PlayStation SBI required games (LibCrypt)
    NSDictionary *sbiRequiredGames =
    @{
      @"SLES-01226" : @1, // Actua Ice Hockey 2 (Europe)
      @"SLES-02563" : @1, // Anstoss - Premier Manager (Germany)
      @"SCES-01564" : @1, // Ape Escape (Europe)
      @"SCES-02028" : @1, // Ape Escape (France)
      @"SCES-02029" : @1, // Ape Escape (Germany)
      @"SCES-02030" : @1, // Ape Escape (Italy)
      @"SCES-02031" : @1, // Ape Escape - La Invasión de los Monos (Spain)
      @"SLES-03324" : @1, // Astérix - Mega Madness (Europe) (En,Fr,De,Es,It,Nl)
      @"SCES-02366" : @1, // Barbie - Aventure Equestre (France)
      @"SCES-02365" : @1, // Barbie - Race & Ride (Europe)
      @"SCES-02367" : @1, // Barbie - Race & Ride (Germany)
      @"SCES-02368" : @1, // Barbie - Race & Ride (Italy)
      @"SCES-02369" : @1, // Barbie - Race & Ride (Spain)
      @"SCES-02488" : @1, // Barbie - Sports Extrême (France)
      @"SCES-02489" : @1, // Barbie - Super Sport (Germany)
      @"SCES-02487" : @1, // Barbie - Super Sports (Europe)
      @"SCES-02490" : @1, // Barbie - Super Sports (Italy)
      @"SCES-02491" : @1, // Barbie - Super Sports (Spain)
      @"SLES-02977" : @1, // BDFL Manager 2001 (Germany)
      @"SLES-03605" : @1, // BDFL Manager 2002 (Germany)
      @"SLES-02293" : @1, // Canal+ Premier Manager (Europe) (Fr,Es,It)
      @"SCES-02834" : @1, // Crash Bash (Europe) (En,Fr,De,Es,It)
      @"SCES-02105" : @1, // CTR - Crash Team Racing (Europe) (En,Fr,De,Es,It,Nl) (EDC) / (No EDC)
      @"SLES-02207" : @1, // Dino Crisis (Europe)
      @"SLES-02208" : @1, // Dino Crisis (France)
      @"SLES-02209" : @1, // Dino Crisis (Germany)
      @"SLES-02210" : @1, // Dino Crisis (Italy)
      @"SLES-02211" : @1, // Dino Crisis (Spain)
      @"SCES-02004" : @1, // Disney Fais Ton Histoire! - Mulan (France)
      @"SCES-02006" : @1, // Disney Libro Animato Creativo - Mulan (Italy)
      @"SCES-01516" : @1, // Disney Tarzan (France)
      @"SCES-01519" : @1, // Disney Tarzan (Spain)
      @"SLES-03191" : @1, // Disney's 102 Dalmatians - Puppies to the Rescue (Europe) (Fr,De,Es,It,Nl)
      @"SLES-03189" : @1, // Disney's 102 Dalmatians - Puppies to the Rescue (Europe)
      @"SCES-02007" : @1, // Disney's Aventura Interactiva - Mulan (Spain)
      @"SCES-01695" : @1, // Disney's Story Studio - Mulan (Europe)
      @"SCES-01431" : @1, // Disney's Tarzan (Europe)
      @"SCES-02185" : @1, // Disney's Tarzan (Netherlands)
      @"SCES-02182" : @1, // Disney's Tarzan (Sweden)
      @"SCES-02264" : @1, // Disney's Verhalenstudio - Mulan (Netherlands)
      @"SCES-02005" : @1, // Disneys Interaktive Abenteuer - Mulan (Germany)
      @"SCES-01517" : @1, // Disneys Tarzan (Germany)
      @"SCES-01518" : @1, // Disneys Tarzan (Italy)
      @"SLES-02538" : @1, // EA Sports Superbike 2000 (Europe) (En,Fr,De,Es,It,Sv)
      @"SLES-01715" : @1, // Eagle One - Harrier Attack (Europe) (En,Fr,De,Es,It)
      @"SCES-01704" : @1, // Esto es Futbol (Spain)
      @"SLES-03061" : @1, // F.A. Premier League Football Manager 2001, The (Europe)
      @"SLES-02722" : @1, // F1 2000 (Europe) (En,Fr,De,Nl)
      @"SLES-02724" : @1, // F1 2000 (Italy)
      @"SLES-02965" : @1, // Final Fantasy IX (Europe) (Disc 1)
      @"SLES-12965" : @1, // Final Fantasy IX (Europe) (Disc 2)
      @"SLES-22965" : @1, // Final Fantasy IX (Europe) (Disc 3)
      @"SLES-32965" : @1, // Final Fantasy IX (Europe) (Disc 4)
      @"SLES-02966" : @1, // Final Fantasy IX (France) (Disc 1)
      @"SLES-12966" : @1, // Final Fantasy IX (France) (Disc 2)
      @"SLES-22966" : @1, // Final Fantasy IX (France) (Disc 3)
      @"SLES-32966" : @1, // Final Fantasy IX (France) (Disc 4)
      @"SLES-02967" : @1, // Final Fantasy IX (Germany) (Disc 1)
      @"SLES-12967" : @1, // Final Fantasy IX (Germany) (Disc 2)
      @"SLES-22967" : @1, // Final Fantasy IX (Germany) (Disc 3)
      @"SLES-32967" : @1, // Final Fantasy IX (Germany) (Disc 4)
      @"SLES-02968" : @1, // Final Fantasy IX (Italy) (Disc 1)
      @"SLES-12968" : @1, // Final Fantasy IX (Italy) (Disc 2)
      @"SLES-22968" : @1, // Final Fantasy IX (Italy) (Disc 3)
      @"SLES-32968" : @1, // Final Fantasy IX (Italy) (Disc 4)
      @"SLES-02969" : @1, // Final Fantasy IX (Spain) (Disc 1)
      @"SLES-12969" : @1, // Final Fantasy IX (Spain) (Disc 2)
      @"SLES-22969" : @1, // Final Fantasy IX (Spain) (Disc 3)
      @"SLES-32969" : @1, // Final Fantasy IX (Spain) (Disc 4)
      @"SLES-02080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 1)
      @"SLES-12080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 2)
      @"SLES-22080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 3)
      @"SLES-32080" : @1, // Final Fantasy VIII (Europe, Australia) (Disc 4)
      @"SLES-02081" : @1, // Final Fantasy VIII (France) (Disc 1)
      @"SLES-12081" : @1, // Final Fantasy VIII (France) (Disc 2)
      @"SLES-22081" : @1, // Final Fantasy VIII (France) (Disc 3)
      @"SLES-32081" : @1, // Final Fantasy VIII (France) (Disc 4)
      @"SLES-02082" : @1, // Final Fantasy VIII (Germany) (Disc 1)
      @"SLES-12082" : @1, // Final Fantasy VIII (Germany) (Disc 2)
      @"SLES-22082" : @1, // Final Fantasy VIII (Germany) (Disc 3)
      @"SLES-32082" : @1, // Final Fantasy VIII (Germany) (Disc 4)
      @"SLES-02083" : @1, // Final Fantasy VIII (Italy) (Disc 1)
      @"SLES-12083" : @1, // Final Fantasy VIII (Italy) (Disc 2)
      @"SLES-22083" : @1, // Final Fantasy VIII (Italy) (Disc 3)
      @"SLES-32083" : @1, // Final Fantasy VIII (Italy) (Disc 4)
      @"SLES-02084" : @1, // Final Fantasy VIII (Spain) (Disc 1)
      @"SLES-12084" : @1, // Final Fantasy VIII (Spain) (Disc 2)
      @"SLES-22084" : @1, // Final Fantasy VIII (Spain) (Disc 3)
      @"SLES-32084" : @1, // Final Fantasy VIII (Spain) (Disc 4)
      @"SLES-02978" : @1, // Football Manager Campionato 2001 (Italy)
      @"SCES-02222" : @1, // Formula One 99 (Europe) (En,Es,Fi)
      @"SCES-01979" : @1, // Formula One 99 (Europe) (En,Fr,De,It)
      @"SLES-02767" : @1, // Frontschweine (Germany)
      @"SCES-01702" : @1, // Fussball Live (Germany)
      @"SLES-03062" : @1, // Fussball Manager 2001 (Germany)
      @"SLES-02328" : @1, // Galerians (Europe) (Disc 1)
      @"SLES-12328" : @1, // Galerians (Europe) (Disc 2)
      @"SLES-22328" : @1, // Galerians (Europe) (Disc 3)
      @"SLES-02329" : @1, // Galerians (France) (Disc 1)
      @"SLES-12329" : @1, // Galerians (France) (Disc 2)
      @"SLES-22329" : @1, // Galerians (France) (Disc 3)
      @"SLES-02330" : @1, // Galerians (Germany) (Disc 1)
      @"SLES-12330" : @1, // Galerians (Germany) (Disc 2)
      @"SLES-22330" : @1, // Galerians (Germany) (Disc 3)
      @"SLES-01241" : @1, // Gekido - Urban Fighters (Europe) (En,Fr,De,Es,It)
      @"SLES-01041" : @1, // Hogs of War (Europe)
      @"SLES-03489" : @1, // Italian Job, The (Europe)
      @"SLES-03626" : @1, // Italian Job, The (Europe) (Fr,De,Es)
      @"SCES-01444" : @1, // Jackie Chan Stuntmaster (Europe)
      @"SLES-01362" : @1, // Le Mans 24 Hours (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-01301" : @1, // Legacy of Kain - Soul Reaver (Europe)
      @"SLES-02024" : @1, // Legacy of Kain - Soul Reaver (France)
      @"SLES-02025" : @1, // Legacy of Kain - Soul Reaver (Germany)
      @"SLES-02027" : @1, // Legacy of Kain - Soul Reaver (Italy)
      @"SLES-02026" : @1, // Legacy of Kain - Soul Reaver (Spain)
      @"SLES-02766" : @1, // Les Cochons de Guerre (France)
      @"SLES-02975" : @1, // LMA Manager 2001 (Europe)
      @"SLES-03603" : @1, // LMA Manager 2002 (Europe)
      @"SLES-03530" : @1, // Lucky Luke - Western Fever (Europe) (En,Fr,De,Es,It,Nl)
      @"SCES-00311" : @1, // MediEvil (Europe)
      @"SCES-01492" : @1, // MediEvil (France)
      @"SCES-01493" : @1, // MediEvil (Germany)
      @"SCES-01494" : @1, // MediEvil (Italy)
      @"SCES-01495" : @1, // MediEvil (Spain)
      @"SCES-02544" : @1, // MediEvil 2 (Europe) (En,Fr,De)
      @"SCES-02545" : @1, // MediEvil 2 (Europe) (Es,It,Pt)
      @"SCES-02546" : @1, // MediEvil 2 (Russia)
      @"SLES-03519" : @1, // Men in Black - The Series - Crashdown (Europe)
      @"SLES-03520" : @1, // Men in Black - The Series - Crashdown (France)
      @"SLES-03521" : @1, // Men in Black - The Series - Crashdown (Germany)
      @"SLES-03522" : @1, // Men in Black - The Series - Crashdown (Italy)
      @"SLES-03523" : @1, // Men in Black - The Series - Crashdown (Spain)
      @"SLES-01545" : @1, // Michelin Rally Masters - Race of Champions (Europe) (En,De,Sv)
      @"SLES-02395" : @1, // Michelin Rally Masters - Race of Champions (Europe) (Fr,Es,It)
      @"SLES-02839" : @1, // Mike Tyson Boxing (Europe) (En,Fr,De,Es,It)
      @"SLES-01906" : @1, // Mission - Impossible (Europe) (En,Fr,De,Es,It)
      @"SLES-02830" : @1, // MoHo (Europe) (En,Fr,De,Es,It)
      @"SCES-01701" : @1, // Monde des Bleus, Le - Le jeu officiel de l'équipe de France (France)
      @"SLES-02086" : @1, // N-Gen Racing (Europe) (En,Fr,De,Es,It)
      @"SLES-02689" : @1, // Need for Speed - Porsche 2000 (Europe) (En,De,Sv)
      @"SLES-02700" : @1, // Need for Speed - Porsche 2000 (Europe) (Fr,Es,It)
      @"SLES-02558" : @1, // Parasite Eve II (Europe) (Disc 1)
      @"SLES-12558" : @1, // Parasite Eve II (Europe) (Disc 2)
      @"SLES-02559" : @1, // Parasite Eve II (France) (Disc 1)
      @"SLES-12559" : @1, // Parasite Eve II (France) (Disc 2)
      @"SLES-02560" : @1, // Parasite Eve II (Germany) (Disc 1)
      @"SLES-12560" : @1, // Parasite Eve II (Germany) (Disc 2)
      @"SLES-02562" : @1, // Parasite Eve II (Italy) (Disc 1)
      @"SLES-12562" : @1, // Parasite Eve II (Italy) (Disc 2)
      @"SLES-02561" : @1, // Parasite Eve II (Spain) (Disc 1)
      @"SLES-12561" : @1, // Parasite Eve II (Spain) (Disc 2)
      @"SLES-02061" : @1, // PGA European Tour Golf (Europe) (En,De)
      @"SLES-02292" : @1, // Premier Manager 2000 (Europe)
      @"SLES-00017" : @1, // Prince Naseem Boxing (Europe) (En,Fr,De,Es,It)
      @"SLES-01943" : @1, // Radikal Bikers (Europe) (En,Fr,De,Es,It)
      @"SLES-02824" : @1, // RC Revenge (Europe) (En,Fr,De,Es)
      @"SLES-02529" : @1, // Resident Evil 3 - Nemesis (Europe)
      @"SLES-02530" : @1, // Resident Evil 3 - Nemesis (France)
      @"SLES-02531" : @1, // Resident Evil 3 - Nemesis (Germany)
      @"SLES-02698" : @1, // Resident Evil 3 - Nemesis (Ireland)
      @"SLES-02533" : @1, // Resident Evil 3 - Nemesis (Italy)
      @"SLES-02532" : @1, // Resident Evil 3 - Nemesis (Spain)
      @"SLES-00995" : @1, // Ronaldo V-Football (Europe) (En,Fr,Nl,Sv)
      @"SLES-02681" : @1, // Ronaldo V-Football (Europe) (De,Es,It,Pt)
      @"SLES-02112" : @1, // SaGa Frontier 2 (Europe)
      @"SLES-02113" : @1, // SaGa Frontier 2 (France)
      @"SLES-02118" : @1, // SaGa Frontier 2 (Germany)
      @"SLES-02763" : @1, // SnoCross Championship Racing (Europe) (En,Fr,De,Es,It)
      @"SCES-02290" : @1, // Space Debris (Europe)
      @"SCES-02430" : @1, // Space Debris (France)
      @"SCES-02431" : @1, // Space Debris (Germany)
      @"SCES-02432" : @1, // Space Debris (Italy)
      @"SCES-01763" : @1, // Speed Freaks (Europe)
      @"SCES-02835" : @1, // Spyro - Year of the Dragon (Europe) (En,Fr,De,Es,It) (v1.0) / (v1.1)
      @"SCES-02104" : @1, // Spyro 2 - Gateway to Glimmer (Europe) (En,Fr,De,Es,It)
      @"SLES-02857" : @1, // Sydney 2000 (Europe)
      @"SLES-02858" : @1, // Sydney 2000 (France)
      @"SLES-02859" : @1, // Sydney 2000 (Germany)
      @"SLES-02861" : @1, // Sydney 2000 (Spain)
      @"SLES-03245" : @1, // TechnoMage - De Terugkeer der Eeuwigheid (Netherlands)
      @"SLES-02831" : @1, // TechnoMage - Die Rückkehr der Ewigkeit (Germany)
      @"SLES-03242" : @1, // TechnoMage - En Quête de L'Eternité (France)
      @"SLES-03241" : @1, // TechnoMage - Return of Eternity (Europe)
      @"SLES-02688" : @1, // Theme Park World (Europe) (En,Fr,De,Es,It,Nl,Sv)
      @"SCES-01882" : @1, // This Is Football (Europe) (Fr,Nl)
      @"SCES-01700" : @1, // This Is Football (Europe)
      @"SCES-01703" : @1, // This Is Football (Italy)
      @"SLES-02572" : @1, // TOCA World Touring Cars (Europe) (En,Fr,De)
      @"SLES-02573" : @1, // TOCA World Touring Cars (Europe) (Es,It)
      @"SLES-02704" : @1, // UEFA Euro 2000 (Europe)
      @"SLES-02705" : @1, // UEFA Euro 2000 (France)
      @"SLES-02706" : @1, // UEFA Euro 2000 (Germany)
      @"SLES-02707" : @1, // UEFA Euro 2000 (Italy)
      @"SLES-01733" : @1, // UEFA Striker (Europe) (En,Fr,De,Es,It,Nl)
      @"SLES-02071" : @1, // Urban Chaos (Europe) (En,Es,It)
      @"SLES-02355" : @1, // Urban Chaos (Germany)
      @"SLES-01907" : @1, // V-Rally - Championship Edition 2 (Europe) (En,Fr,De)
      @"SLES-02754" : @1, // Vagrant Story (Europe)
      @"SLES-02755" : @1, // Vagrant Story (France)
      @"SLES-02756" : @1, // Vagrant Story (Germany)
      @"SLES-02733" : @1, // Walt Disney World Quest - Magical Racing Tour (Europe) (En,Fr,De,Es,It,Nl,Sv,No,Da)
      @"SCES-01909" : @1, // Wip3out (Europe) (En,Fr,De,Es,It)
      };

    // PlayStation Multitap supported games (incomplete list)
    NSDictionary *multiTapGames =
    @{
      @"SLES-02339" : @3, // Arcade Party Pak (Europe, Australia)
      @"SLUS-00952" : @3, // Arcade Party Pak (USA)
      @"SLES-02537" : @3, // Bishi Bashi Special (Europe)
      @"SLPM-86123" : @3, // Bishi Bashi Special (Japan)
      @"SLPM-86539" : @3, // Bishi Bashi Special 3: Step Champ (Japan)
      @"SLPS-01701" : @3, // Capcom Generation - Dai 4 Shuu Kokou no Eiyuu (Japan)
      @"SLPS-01567" : @3, // Captain Commando (Japan)
      @"SLUS-00682" : @3, // Jeopardy! (USA)
      @"SLUS-01173" : @3, // Jeopardy! 2nd Edition (USA)
      @"SLES-03752" : @3, // Quiz Show (Italy) (Disc 1)
      @"SLES-13752" : @3, // Quiz Show (Italy) (Disc 2)
      @"SLES-02849" : @3, // Rampage - Through Time (Europe) (En,Fr,De)
      @"SLUS-01065" : @3, // Rampage - Through Time (USA)
      @"SLES-02021" : @3, // Rampage 2 - Universal Tour (Europe)
      @"SLUS-00742" : @3, // Rampage 2 - Universal Tour (USA)
      @"SLUS-01174" : @3, // Wheel of Fortune - 2nd Edition (USA)
      @"SLES-03499" : @3, // You Don't Know Jack (Germany)
      @"SLUS-00716" : @3, // You Don't Know Jack (USA) (Disc 1)
      @"SLUS-00762" : @3, // You Don't Know Jack (USA) (Disc 2)
      @"SLUS-01194" : @3, // You Don't Know Jack - Mock 2 (USA)
      @"SLES-00015" : @4, // Actua Golf (Europe) (En,Fr,De)
      @"SLPS-00298" : @4, // Actua Golf (Japan)
      @"SLUS-00198" : @4, // VR Golf '97 (USA) (En,Fr)
      @"SLES-00044" : @4, // Actua Golf 2 (Europe)
      @"SLUS-00636" : @4, // FOX Sports Golf '99 (USA)
      @"SLES-01042" : @4, // Actua Golf 3 (Europe)
      @"SLES-00188" : @4, // Actua Ice Hockey (Europe) (En,Fr,De,Sv,Fi)
      @"SLPM-86078" : @4, // Actua Ice Hockey (Japan)
      @"SLES-01226" : @4, // Actua Ice Hockey 2 (Europe)
      @"SLES-00021" : @4, // Actua Soccer 2 (Europe) (En,Fr)
      @"SLES-01029" : @4, // Actua Soccer 2 (Germany) (En,De)
      @"SLES-01028" : @4, // Actua Soccer 2 (Italy)
      @"SLES-00265" : @4, // Actua Tennis (Europe)
      @"SLES-01396" : @4, // Actua Tennis (Europe) (Fr,De)
      @"SLES-00189" : @4, // Adidas Power Soccer (Europe) (En,Fr,De,Es,It)
      @"SCUS-94502" : @4, // Adidas Power Soccer (USA)
      @"SLES-00857" : @4, // Adidas Power Soccer 2 (Europe) (En,Fr,De,Es,It,Nl)
      @"SLES-00270" : @4, // Adidas Power Soccer International '97 (Europe) (En,Fr,De,Es,It,Nl)
      @"SLES-01239" : @4, // Adidas Power Soccer 98 (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-00547" : @4, // Adidas Power Soccer 98 (USA)
      @"SLES-03963" : @4, // All Star Tennis (Europe)
      @"SLPS-02228" : @4, // Simple 1500 Series Vol. 26 - The Tennis (Japan)
      @"SLUS-01348" : @4, // Tennis (USA)
      @"SLES-01433" : @4, // All Star Tennis '99 (Europe) (En,Fr,De,Es,It)
      @"SLES-02764" : @4, // All Star Tennis 2000 (Europe) (En,De,Es,It)
      @"SLES-02765" : @4, // All Star Tennis 2000 (France)
      @"SCES-00263" : @4, // Namco Tennis Smash Court (Europe)
      @"SLPS-00450" : @4, // Smash Court (Japan)
      @"SCES-01833" : @4, // Anna Kournikova's Smash Court Tennis (Europe)
      @"SLPS-01693" : @4, // Smash Court 2 (Japan)
      @"SLPS-03001" : @4, // Smash Court 3 (Japan)
      @"SLES-03579" : @4, // Junior Sports Football (Europe)
      @"SLES-03581" : @4, // Junior Sports Fussball (Germany)
      @"SLUS-01094" : @4, // Backyard Soccer (USA)
      @"SLES-03210" : @4, // Hunter, The (Europe)
      @"SLPM-86400" : @4, // SuperLite 1500 Series - Battle Sugoroku the Hunter - A.R.0062 (Japan)
      @"SLUS-01335" : @4, // Battle Hunter (USA)
      @"SLES-00476" : @4, // Blast Chamber (Europe) (En,Fr,De,Es,It)
      @"SLPS-00622" : @4, // Kyuu Bakukku (Japan)
      @"SLUS-00219" : @4, // Blast Chamber (USA)
      @"SLES-00845" : @4, // Blaze & Blade - Eternal Quest (Europe)
      @"SLES-01274" : @4, // Blaze & Blade - Eternal Quest (Germany)
      @"SLPS-01209" : @4, // Blaze & Blade - Eternal Quest (Japan)
      @"SLPS-01576" : @4, // Blaze & Blade Busters (Japan)
      @"SCES-01443" : @4, // Blood Lines (Europe) (En,Fr,De,Es,It)
      @"SLPS-03002" : @4, // Bomberman Land (Japan) (v1.0) / (v1.1) / (v1.2)
      @"SLES-00258" : @4, // Break Point (Europe) (En,Fr)
      @"SLES-02854" : @4, // Break Out (Europe) (En,Fr,De,It)
      @"SLUS-01170" : @4, // Break Out (USA)
      @"SLES-00759" : @4, // Brian Lara Cricket (Europe)
      @"SLES-01486" : @4, // Caesars Palace II (Europe)
      @"SLES-02476" : @4, // Caesars Palace 2000 - Millennium Gold Edition (Europe)
      @"SLUS-01089" : @4, // Caesars Palace 2000 - Millennium Gold Edition (USA)
      @"SLES-03206" : @4, // Card Shark (Europe)
      @"SLPS-02225" : @4, // Trump Shiyouyo! (Japan) (v1.0)
      @"SLPS-02612" : @4, // Trump Shiyouyo! (Japan) (v1.1)
      @"SLES-02825" : @4, // Catan - Die erste Insel (Germany)
      @"SLUS-00886" : @4, // Chessmaster II (USA)
      @"SLES-00753" : @4, // Circuit Breakers (Europe) (En,Fr,De,Es,It)
      @"SLUS-00697" : @4, // Circuit Breakers (USA)
      @"SLUS-00196" : @4, // College Slam (USA)
      @"SCES-02834" : @4, // Crash Bash (Europe) (En,Fr,De,Es,It)
      @"SCPS-10140" : @4, // Crash Bandicoot Carnival (Japan)
      @"SCUS-94570" : @4, // Crash Bash (USA)
      @"SCES-02105" : @4, // CTR - Crash Team Racing (Europe) (En,Fr,De,Es,It,Nl) (EDC) / (No EDC)
      @"SCPS-10118" : @4, // Crash Bandicoot Racing (Japan)
      @"SCUS-94426" : @4, // CTR - Crash Team Racing (USA)
      @"SLES-02371" : @4, // CyberTiger (Australia)
      @"SLES-02370" : @4, // CyberTiger (Europe) (En,Fr,De,Es,Sv)
      @"SLUS-01004" : @4, // CyberTiger (USA)
      @"SLES-03488" : @4, // David Beckham Soccer (Europe)
      @"SLES-03682" : @4, // David Beckham Soccer (Europe) (Fr,De,Es,It)
      @"SLUS-01455" : @4, // David Beckham Soccer (USA)
      @"SLES-00096" : @4, // Davis Cup Complete Tennis (Europe)
      @"SCES-03705" : @4, // Disney's Party Time with Winnie the Pooh (Europe)
      @"SCES-03744" : @4, // Disney's Winnie l'Ourson - C'est la récré! (France)
      @"SCES-03745" : @4, // Disney's Party mit Winnie Puuh (Germany)
      @"SCES-03749" : @4, // Disney Pooh e Tigro! E Qui la Festa (Italy)
      @"SLPS-03460" : @4, // Pooh-San no Minna de Mori no Daikyosou! (Japan)
      @"SCES-03746" : @4, // Disney's Spelen met Winnie de Poeh en zijn Vriendjes! (Netherlands)
      @"SCES-03748" : @4, // Disney Ven a la Fiesta! con Winnie the Pooh (Spain)
      @"SLUS-01437" : @4, // Disney's Pooh's Party Game - In Search of the Treasure (USA)
      @"SLPS-00155" : @4, // DX Jinsei Game (Japan)
      @"SLPS-00918" : @4, // DX Jinsei Game II (Japan) (v1.0) / (v1.1)
      @"SLPS-02469" : @4, // DX Jinsei Game III (Japan)
      @"SLPM-86963" : @4, // DX Jinsei Game IV (Japan)
      @"SLPM-87187" : @4, // DX Jinsei Game V (Japan)
      @"SLES-02823" : @4, // ECW Anarchy Rulz (Europe)
      @"SLES-03069" : @4, // ECW Anarchy Rulz (Germany)
      @"SLUS-01169" : @4, // ECW Anarchy Rulz (USA)
      @"SLES-02535" : @4, // ECW Hardcore Revolution (Europe) (v1.0) / (v1.1)
      @"SLES-02536" : @4, // ECW Hardcore Revolution (Germany) (v1.0) / (v1.1)
      @"SLUS-01045" : @4, // ECW Hardcore Revolution (USA)
      @"SLUS-01186" : @4, // ESPN MLS Gamenight (USA)
      @"SLES-03082" : @4, // European Super League (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-02142" : @4, // F.A. Premier League Stars, The (Europe)
      @"SLES-02143" : @4, // Bundesliga Stars 2000 (Germany)
      @"SLES-02702" : @4, // Primera Division Stars (Spain)
      @"SLES-03063" : @4, // F.A. Premier League Stars 2001, The (Europe)
      @"SLES-03064" : @4, // LNF Stars 2001 (France)
      @"SLES-03065" : @4, // Bundesliga Stars 2001 (Germany)
      @"SLES-00548" : @4, // Fantastic Four (Europe) (En,Fr,De,Es,It)
      @"SLPS-01034" : @4, // Fantastic Four (Japan)
      @"SLUS-00395" : @4, // Fantastic Four (USA)
      @"SLPS-02065" : @4, // Fire Pro Wrestling G (Japan) (v1.0)
      @"SLPS-02817" : @4, // Fire Pro Wrestling G (Japan) (v1.1)
      @"SLES-00704" : @4, // Frogger (Europe) (En,Fr,De,Es,It)
      @"SLPS-01399" : @4, // Frogger (Japan)
      @"SLUS-00506" : @4, // Frogger (USA)
      @"SLES-02853" : @4, // Frogger 2 - Swampy's Revenge (Europe) (En,Fr,De,It)
      @"SLUS-01172" : @4, // Frogger 2 - Swampy's Revenge (USA)
      @"SLES-01241" : @4, // Gekido - Urban Fighters (Europe) (En,Fr,De,Es,It)
      @"SLUS-00970" : @4, // Gekido - Urban Fighters (USA)
      @"SLPM-86761" : @4, // Simple 1500 Series Vol. 60 - The Table Hockey (Japan)
      @"SLPS-03362" : @4, // Simple Character 2000 Series Vol. 05 - High School Kimengumi - The Table Hockey (Japan)
      @"SLES-01041" : @4, // Hogs of War (Europe)
      @"SLUS-01195" : @4, // Hogs of War (USA)
      @"SCES-00983" : @4, // Everybody's Golf (Europe) (En,Fr,De,Es,It)
      @"SCPS-10042" : @4, // Minna no Golf (Japan)
      @"SCUS-94188" : @4, // Hot Shots Golf (USA)
      @"SCES-02146" : @4, // Everybody's Golf 2 (Europe)
      @"SCPS-10093" : @4, // Minna no Golf 2 (Japan) (v1.0)
      @"SCUS-94476" : @4, // Hot Shots Golf 2 (USA)
      @"SLES-03595" : @4, // Hot Wheels - Extreme Racing (Europe)
      @"SLUS-01293" : @4, // Hot Wheels - Extreme Racing (USA)
      @"SLPM-86651" : @4, // Hunter X Hunter - Maboroshi no Greed Island (Japan)
      @"SLES-00309" : @4, // Hyper Tennis - Final Match (Europe)
      @"SLES-00309" : @4, // Hyper Final Match Tennis (Japan)
      @"SLES-02550" : @4, // International Superstar Soccer (Europe) (En,De)
      @"SLES-03149" : @4, // International Superstar Soccer (Europe) (Fr,Es,It)
      @"SLPM-86317" : @4, // Jikkyou J. League 1999 - Perfect Striker (Japan)
      @"SLES-00511" : @4, // International Superstar Soccer Deluxe (Europe)
      @"SLPM-86538" : @4, // J. League Jikkyou Winning Eleven 2000 (Japan)
      @"SLPM-86668" : @4, // J. League Jikkyou Winning Eleven 2000 2nd (Japan)
      @"SLPM-86835" : @4, // J. League Jikkyou Winning Eleven 2001 (Japan)
      @"SLES-00333" : @4, // International Track & Field (Europe)
      @"SLPM-86002" : @4, // Hyper Olympic in Atlanta (Japan)
      @"SLUS-00238" : @4, // International Track & Field (USA)
      @"SLES-02448" : @4, // International Track & Field 2 (Europe)
      @"SLPM-86482" : @4, // Ganbare! Nippon! Olympic 2000 (Japan)
      @"SLUS-00987" : @4, // International Track & Field 2000 (USA)
      @"SLES-02424" : @4, // ISS Pro Evolution (Europe) (Es,It)
      @"SLES-02095" : @4, // ISS Pro Evolution (Europe) (En,Fr,De) (EDC) / (No EDC)
      @"SLPM-86291" : @4, // World Soccer Jikkyou Winning Eleven 4 (Japan) (v1.0) / (v1.1)
      @"SLUS-01014" : @4, // ISS Pro Evolution (USA)
      @"SLES-03321" : @4, // ISS Pro Evolution 2 (Europe) (En,Fr,De)
      @"SLPM-86600" : @4, // World Soccer Jikkyou Winning Eleven 2000 - U-23 Medal e no Chousen (Japan)
      @"SLPS-00832" : @4, // Iwatobi Penguin Rocky x Hopper (Japan)
      @"SLPS-01283" : @4, // Iwatobi Penguin Rocky x Hopper 2 - Tantei Monogatari (Japan)
      @"SLES-02572" : @4, // TOCA World Touring Cars (Europe) (En,Fr,De)
      @"SLES-02573" : @4, // TOCA World Touring Cars (Europe) (Es,It)
      @"SLPS-02852" : @4, // WTC World Touring Car Championship (Japan)
      @"SLUS-01139" : @4, // Jarrett & Labonte Stock Car Racing (USA)
      @"SLES-03328" : @4, // Jetracer (Europe) (En,Fr,De)
      @"SLES-00377" : @4, // Jonah Lomu Rugby (Europe) (En,De,Es,It)
      @"SLES-00611" : @4, // Jonah Lomu Rugby (France)
      @"SLPS-01268" : @4, // Great Rugby Jikkyou '98 - World Cup e no Michi (Japan)
      @"SLES-01061" : @4, // Kick Off World (Europe) (En,Fr)
      @"SLES-01327" : @4, // Kick Off World (Europe) (Es,Nl)
      @"SLES-01062" : @4, // Kick Off World (Germany)
      @"SLES-01328" : @4, // Kick Off World (Greece)
      @"SLES-01063" : @4, // Kick Off World Manager (Italy)
      @"SCES-03922" : @4, // Klonoa - Beach Volleyball (Europe) (En,Fr,De,Es,It)
      @"SLPS-03433" : @4, // Klonoa Beach Volley - Saikyou Team Ketteisen! (Japan)
      @"SLUS-01125" : @4, // Kurt Warner's Arena Football Unleashed (USA)
      @"SLPS-00686" : @4, // Love Game's - Wai Wai Tennis (Japan)
      @"SLES-02272" : @4, // Yeh Yeh Tennis (Europe) (En,Fr,De)
      @"SLPS-02983" : @4, // Love Game's - Wai Wai Tennis 2 (Japan)
      @"SLPM-86899" : @4, // Love Game's -  Wai Wai Tennis Plus (Japan)
      @"SLES-01594" : @4, // Michael Owen's World League Soccer 99 (Europe) (En,Fr,It)
      @"SLES-02499" : @4, // Midnight in Vegas (Europe) (En,Fr,De) (v1.0) / (v1.1)
      @"SLUS-00836" : @4, // Vegas Games 2000 (USA)
      @"SLES-03246" : @4, // Monster Racer (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-03813" : @4, // Monte Carlo Games Compendium (Europe) (Disc 1)
      @"SLES-13813" : @4, // Monte Carlo Games Compendium (Europe) (Disc 2)
      @"SLES-00945" : @4, // Monopoly (Europe) (En,Fr,De,Es,Nl) (v1.0) / (v1.1)
      @"SLPS-00741" : @4, // Monopoly (Japan)
      @"SLES-00310" : @4, // Motor Mash (Europe) (En,Fr,De)
      @"SCES-03085" : @4, // Ms. Pac-Man Maze Madness (Europe) (En,Fr,De,Es,It)
      @"SLPS-03000" : @4, // Ms. Pac-Man Maze Madness (Japan)
      @"SLUS-01018" : @4, // Ms. Pac-Man Maze Madness (USA) (v1.0) / (v1.1)
      @"SLES-02224" : @4, // Music 2000 (Europe) (En,Fr,De,Es,It)
      @"SLUS-01006" : @4, // MTV Music Generator (USA)
      @"SLES-00999" : @4, // Nagano Winter Olympics '98 (Europe)
      @"SLPM-86056" : @4, // Hyper Olympic in Nagano (Japan)
      @"SLUS-00591" : @4, // Nagano Winter Olympics '98 (USA)
      @"SLUS-00329" : @4, // NBA Hangtime (USA)
      @"SLES-00529" : @4, // NBA Jam Extreme (Europe)
      @"SLPS-00699" : @4, // NBA Jam Extreme (Japan)
      @"SLUS-00388" : @4, // NBA Jam Extreme (USA)
      @"SLES-00068" : @4, // NBA Jam - Tournament Edition (Europe)
      @"SLPS-00199" : @4, // NBA Jam - Tournament Edition (Japan)
      @"SLUS-00002" : @4, // NBA Jam - Tournament Edition (USA)
      @"SLES-02336" : @4, // NBA Showtime - NBA on NBC (Europe)
      @"SLUS-00948" : @4, // NBA Showtime - NBA on NBC (USA)
      @"SLES-02689" : @4, // Need for Speed - Porsche 2000 (Europe) (En,De,Sv)
      @"SLES-02700" : @4, // Need for Speed - Porsche 2000 (Europe) (Fr,Es,It)
      @"SLUS-01104" : @4, // Need for Speed - Porsche Unleashed (USA)
      @"SLES-01907" : @4, // V-Rally - Championship Edition 2 (Europe) (En,Fr,De)
      @"SLPS-02516" : @4, // V-Rally - Championship Edition 2 (Japan)
      @"SLUS-01003" : @4, // Need for Speed - V-Rally 2 (USA)
      @"SLES-02335" : @4, // NFL Blitz 2000 (Europe)
      @"SLUS-00861" : @4, // NFL Blitz 2000 (USA)
      @"SLUS-01146" : @4, // NFL Blitz 2001 (USA)
      @"SLUS-00327" : @4, // NHL Open Ice - 2 on 2 Challenge (USA)
      @"SLES-00113" : @4, // Olympic Soccer (Europe) (En,Fr,De,Es,It)
      @"SLPS-00523" : @4, // Olympic Soccer (Japan)
      @"SLUS-00156" : @4, // Olympic Soccer (USA)
      @"SLPS-03056" : @4, // Oshigoto-shiki Jinsei Game - Mezase Shokugyou King (Japan)
      @"SLPS-00899" : @4, // Panzer Bandit (Japan)
      @"SLPM-86016" : @4, // Paro Wars (Japan)
      @"SLUS-01130" : @4, // Peter Jacobsen's Golden Tee Golf (USA)
      @"SLES-00201" : @4, // Pitball (Europe) (En,Fr,De,Es,It)
      @"SLPS-00607" : @4, // Pitball (Japan)
      @"SLUS-00146" : @4, // Pitball (USA)
      @"SLUS-01033" : @4, // Polaris SnoCross (USA)
      @"SLES-02020" : @4, // Pong (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-00889" : @4, // Pong - The Next Level (USA)
      @"SLES-02808" : @4, // Beach Volleyball (Europe) (En,Fr,De,Es,It)
      @"SLUS-01196" : @4, // Power Spike - Pro Beach Volleyball (USA)
      @"SLES-00785" : @4, // Poy Poy (Europe)
      @"SLPM-86034" : @4, // Poitters' Point (Japan)
      @"SLUS-00486" : @4, // Poy Poy (USA)
      @"SLES-01536" : @4, // Poy Poy 2 (Europe)
      @"SLPM-86061" : @4, // Poitters' Point 2 - Sodom no Inbou
      @"SLES-01544" : @4, // Premier Manager Ninety Nine (Europe)
      @"SLES-01864" : @4, // Premier Manager Novanta Nove (Italy)
      @"SLES-02292" : @4, // Premier Manager 2000 (Europe)
      @"SLES-02293" : @4, // Canal+ Premier Manager (Europe) (Fr,Es,It)
      @"SLES-02563" : @4, // Anstoss - Premier Manager (Germany)
      @"SLES-00738" : @4, // Premier Manager 98 (Europe)
      @"SLES-01284" : @4, // Premier Manager 98 (Italy)
      @"SLES-03795" : @4, // Pro Evolution Soccer (Europe) (En,Fr,De)
      @"SLES-03796" : @4, // Pro Evolution Soccer (Europe) (Es,It)
      @"SLES-03946" : @4, // Pro Evolution Soccer 2 (Europe) (En,Fr,De)
      @"SLES-03957" : @4, // Pro Evolution Soccer 2 (Europe) (Es,It)
      @"SLPM-87056" : @4, // World Soccer Winning Eleven 2002 (Japan)
      @"SLPM-86868" : @4, // Simple 1500 Series Vol. 69 - The Putter Golf (Japan)
      @"SLUS-01371" : @4, // Putter Golf (USA)
      @"SLPS-03114" : @4, // Puyo Puyo Box (Japan)
      @"SLUS-00757" : @4, // Quake II (USA)
      @"SLPS-02909" : @4, // Simple 1500 Series Vol. 34 - The Quiz Bangumi (Japan)
      @"SLPS-03384" : @4, // Nice Price Series Vol. 06 - Quiz de Battle (Japan)
      @"SLES-03511" : @4, // Rageball (Europe)
      @"SLUS-01461" : @4, // Rageball (USA)
      @"SLPM-86272" : @4, // Rakugaki Showtime
      @"SCES-00408" : @4, // Rally Cross (Europe)
      @"SIPS-60022" : @4, // Rally Cross (Japan)
      @"SCUS-94308" : @4, // Rally Cross (USA)
      @"SLES-01103" : @4, // Rat Attack (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-00656" : @4, // Rat Attack! (USA)
      @"SLES-00707" : @4, // Risk (Europe) (En,Fr,De,Es)
      @"SLUS-00616" : @4, // Risk - The Game of Global Domination (USA)
      @"SLES-02552" : @4, // Road Rash - Jailbreak (Europe) (En,Fr,De)
      @"SLUS-01053" : @4, // Road Rash - Jailbreak (USA)
      @"SCES-01630" : @4, // Running Wild (Europe)
      @"SCUS-94272" : @4, // Running Wild (USA)
      @"SLES-00217" : @4, // Sampras Extreme Tennis (Europe) (En,Fr,De,Es,It)
      @"SLPS-00594" : @4, // Sampras Extreme Tennis (Japan)
      @"SLES-01286" : @4, // S.C.A.R.S. (Europe) (En,Fr,De,Es,It)
      @"SLUS-00692" : @4, // S.C.A.R.S. (USA)
      @"SLES-03642" : @4, // Scrabble (Europe) (En,De,Es)
      @"SLUS-00903" : @4, // Scrabble (USA)
      @"SLPS-02912" : @4, // SD Gundam - G Generation-F (Japan) (Disc 1)
      @"SLPS-02913" : @4, // SD Gundam - G Generation-F (Japan) (Disc 2)
      @"SLPS-02914" : @4, // SD Gundam - G Generation-F (Japan) (Disc 3)
      @"SLPS-02915" : @4, // SD Gundam - G Generation-F (Japan) (Premium Disc)
      @"SLPS-03195" : @4, // SD Gundam - G Generation-F.I.F (Japan)
      @"SLPS-00785" : @4, // SD Gundam - GCentury (Japan) (v1.0) / (v1.1)
      @"SLPS-01560" : @4, // SD Gundam - GGeneration (Japan) (v1.0) / (v1.1)
      @"SLPS-01561" : @4, // SD Gundam - GGeneration (Premium Disc) (Japan)
      @"SLPS-02200" : @4, // SD Gundam - GGeneration-0 (Japan) (Disc 1) (v1.0)
      @"SLPS-02201" : @4, // SD Gundam - GGeneration-0 (Japan) (Disc 2) (v1.0)
      @"SLES-03776" : @4, // Sky Sports Football Quiz (Europe)
      @"SLES-03856" : @4, // Sky Sports Football Quiz - Season 02 (Europe)
      @"SLES-00076" : @4, // Slam 'n Jam '96 featuring Magic & Kareem (Europe)
      @"SLPS-00426" : @4, // Magic Johnson to Kareem Abdul-Jabbar no Slam 'n Jam '96 (Japan)
      @"SLUS-00022" : @4, // Slam 'n Jam '96 featuring Magic & Kareem (USA)
      @"SLES-02194" : @4, // Sled Storm (Europe) (En,Fr,De,Es)
      @"SLUS-00955" : @4, // Sled Storm (USA)
      @"SLES-01972" : @4, // South Park - Chef's Luv Shack (Europe)
      @"SLUS-00997" : @4, // South Park - Chef's Luv Shack (USA)
      @"SCES-01763" : @4, // Speed Freaks (Europe)
      @"SCUS-94563" : @4, // Speed Punks (USA)
      @"SLES-00023" : @4, // Striker 96 (Europe) (v1.0)
      @"SLPS-00127" : @4, // Striker - World Cup Premiere Stage (Japan)
      @"SLUS-00210" : @4, // Striker 96 (USA)
      @"SLES-01733" : @4, // UEFA Striker (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-01078" : @4, // Striker Pro 2000 (USA)
      @"SLPS-01264" : @4, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 1)
      @"SLPS-01265" : @4, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 2)
      @"SLES-00213" : @4, // Syndicate Wars (Europe) (En,Fr,Es,It,Sv)
      @"SLES-00212" : @4, // Syndicate Wars (Germany)
      @"SLUS-00262" : @4, // Syndicate Wars (USA)
      @"SLPS-03050" : @4, // Tales of Eternia (Japan) (Disc 1)
      @"SLPS-03051" : @4, // Tales of Eternia (Japan) (Disc 2)
      @"SLPS-03052" : @4, // Tales of Eternia (Japan) (Disc 3)
      @"SLUS-01355" : @4, // Tales of Destiny II (USA) (Disc 1)
      @"SLUS-01367" : @4, // Tales of Destiny II (USA) (Disc 2)
      @"SLUS-01368" : @4, // Tales of Destiny II (USA) (Disc 3)
      @"SCES-01923" : @4, // Team Buddies (Europe) (En,Fr,De)
      @"SLUS-00869" : @4, // Team Buddies (USA)
      @"SLPS-00321" : @4, // Tetris X (Japan)
      @"SLES-01675" : @4, // Tiger Woods 99 USA Tour Golf (Australia)
      @"SLES-01674" : @4, // Tiger Woods 99 PGA Tour Golf (Europe) (En,Fr,De,Es,Sv)
      @"SLPS-02012" : @4, // Tiger Woods 99 PGA Tour Golf (Japan)
      @"SLUS-00785" : @4, // Tiger Woods 99 PGA Tour Golf (USA) (v1.0) / (v1.1)
      @"SLES-03148" : @4, // Tiger Woods PGA Tour Golf (Europe)
      @"SLUS-01273" : @4, // Tiger Woods PGA Tour Golf (USA)
      @"SLES-02595" : @4, // Tiger Woods USA Tour 2000 (Australia)
      @"SLES-02551" : @4, // Tiger Woods PGA Tour 2000 (Europe) (En,Fr,De,Es,Sv)
      @"SLUS-01054" : @4, // Tiger Woods PGA Tour 2000 (USA)
      @"SLPS-01113" : @4, // Toshinden Card Quest (Japan)
      @"SLES-00256" : @4, // Trash It (Europe) (En,Fr,De,Es,It)
      @"SCUS-94249" : @4, // Twisted Metal III (USA) (v1.0) / (v1.1)
      @"SCUS-94560" : @4, // Twisted Metal 4 (USA)
      @"SLES-02806" : @4, // UEFA Challenge (Europe) (En,Fr,De,Nl)
      @"SLES-02807" : @4, // UEFA Challenge (Europe) (Fr,Es,It,Pt)
      @"SLES-01622" : @4, // UEFA Champions League - Season 1998-99 (Europe)
      @"SLES-01745" : @4, // UEFA Champions League - Saison 1998-99 (Germany)
      @"SLES-01746" : @4, // UEFA Champions League - Stagione 1998-99 (Italy)
      @"SLES-02918" : @4, // Vegas Casino (Europe)
      @"SLPS-00467" : @4, // Super Casino Special (Japan)
      @"SLES-00761" : @4, // Viva Football (Europe) (En,Fr,De,Es,It,Pt)
      @"SLES-01341" : @4, // Absolute Football (France) (En,Fr,De,Es,It,Pt)
      @"SLUS-00953" : @4, // Viva Soccer (USA) (En,Fr,De,Es,It,Pt)
      @"SLES-02193" : @4, // WCW Mayhem (Europe)
      @"SLUS-00963" : @4, // WCW Mayhem (USA)
      @"SLES-03806" : @4, // Westlife - Fan-O-Mania (Europe)
      @"SLES-03779" : @4, // Westlife - Fan-O-Mania (Europe) (Fr,De)
      @"SLES-00717" : @4, // World League Soccer '98 (Europe) (En,Es,It)
      @"SLES-01166" : @4, // World League Soccer '98 (France)
      @"SLES-01167" : @4, // World League Soccer '98 (Germany)
      @"SLPS-01389" : @4, // World League Soccer (Japan)
      @"SLES-02170" : @4, // Wu-Tang - Taste the Pain (Europe)
      @"SLES-02171" : @4, // Wu-Tang - Shaolin Style (France)
      @"SLES-02172" : @4, // Wu-Tang - Shaolin Style (Germany)
      @"SLUS-00929" : @4, // Wu-Tang - Shaolin Style (USA)
      @"SLES-01980" : @4, // WWF Attitude (Europe)
      @"SLES-02255" : @4, // WWF Attitude (Germany)
      @"SLUS-00831" : @4, // WWF Attitude (USA)
      @"SLES-00286" : @4, // WWF In Your House (Europe)
      @"SLPS-00695" : @4, // WWF In Your House (Japan)
      @"SLUS-00246" : @4, // WWF In Your House (USA) (v1.0) / (v1.1)
      @"SLES-02619" : @4, // WWF SmackDown! (Europe)
      @"SLPS-02885" : @4, // Exciting Pro Wres (Japan)
      @"SLUS-00927" : @4, // WWF SmackDown! (USA)
      @"SLES-03251" : @4, // WWF SmackDown! 2 - Know Your Role (Europe)
      @"SLPS-03122" : @4, // Exciting Pro Wres 2 (Japan)
      @"SLUS-01234" : @4, // WWF SmackDown! 2 - Know Your Role (USA)
      @"SLES-00804" : @4, // WWF War Zone (Europe)
      @"SLUS-00495" : @4, // WWF War Zone (USA) (v1.0) / (v1.1)
      @"SLES-01893" : @5, // Bomberman (Europe)
      @"SLPS-01717" : @5, // Bomberman (Japan)
      @"SLUS-01189" : @5, // Bomberman - Party Edition (USA)
      @"SCES-01078" : @5, // Bomberman World (Europe) (En,Fr,De,Es,It)
      @"SLPS-01155" : @5, // Bomberman World (Japan)
      @"SLUS-00680" : @5, // Bomberman World (USA)
      @"SCES-01312" : @5, // Devil Dice (Europe) (En,Fr,De,Es,It)
      @"SCPS-10051" : @5, // XI [sai] (Japan) (En,Ja)
      @"SLUS-00672" : @5, // Devil Dice (USA)
      @"SLPS-02943" : @5, // DX Monopoly (Japan)
      @"SLES-00865" : @5, // Overboard! (Europe)
      @"SLUS-00558" : @5, // Shipwreckers! (USA)
      @"SLES-01376" : @6, // Brunswick Circuit Pro Bowling (Europe)
      @"SLUS-00571" : @6, // Brunswick Circuit Pro Bowling (USA)
      @"SLUS-00769" : @6, // Game of Life, The (USA)
      @"SLES-03362" : @6, // NBA Hoopz (Europe) (En,Fr,De)
      @"SLUS-01331" : @6, // NBA Hoopz (USA)
      @"SLES-00284" : @6, // Space Jam (Europe)
      @"SLPS-00697" : @6, // Space Jam (Japan)
      @"SLUS-00243" : @6, // Space Jam (USA)
      @"SLES-00534" : @6, // Ten Pin Alley (Europe)
      @"SLUS-00377" : @6, // Ten Pin Alley (USA)
      @"SLPS-01243" : @6, // Tenant Wars (Japan)
      @"SLPM-86240" : @6, // SuperLite 1500 Series - Tenant Wars Alpha - SuperLite 1500 Version (Japan)
      @"SLUS-01333" : @6, // Board Game - Top Shop (USA)
      @"SLES-03830" : @8, // 2002 FIFA World Cup Korea Japan (Europe) (En,Sv)
      @"SLES-03831" : @8, // Coupe du Monde FIFA 2002 (France)
      @"SLES-03832" : @8, // 2002 FIFA World Cup Korea Japan (Germany)
      @"SLES-03833" : @8, // 2002 FIFA World Cup Korea Japan (Italy)
      @"SLES-03834" : @8, // 2002 FIFA World Cup Korea Japan (Spain)
      @"SLUS-01449" : @8, // 2002 FIFA World Cup (USA) (En,Es)
      @"SLES-01210" : @8, // Actua Soccer 3 (Europe)
      @"SLES-01644" : @8, // Actua Soccer 3 (France)
      @"SLES-01645" : @8, // Actua Soccer 3 (Germany)
      @"SLES-01646" : @8, // Actua Soccer 3 (Italy)
      @"SLPM-86044" : @8, // Break Point (Japan)
      @"SCUS-94156" : @8, // Cardinal Syn (USA)
      @"SLES-02948" : @8, // Chris Kamara's Street Soccer (Europe)
      @"SLES-00080" : @8, // Supersonic Racers (Europe) (En,Fr,De,Es,It)
      @"SLPS-01025" : @8, // Dare Devil Derby 3D (Japan)
      @"SLUS-00300" : @8, // Dare Devil Derby 3D (USA)
      @"SLES-00116" : @8, // FIFA Soccer 96 (Europe) (En,Fr,De,Es,It,Sv)
      @"SLUS-00038" : @8, // FIFA Soccer 96 (USA)
      @"SLES-00504" : @8, // FIFA 97 (Europe) (En,Fr,De,Es,It,Sv)
      @"SLES-00505" : @8, // FIFA 97 (France) (En,Fr,De,Es,It,Sv)
      @"SLES-00506" : @8, // FIFA 97 (Germany) (En,Fr,De,Es,It,Sv)
      @"SLPS-00878" : @8, // FIFA Soccer 97 (Japan)
      @"SLUS-00269" : @8, // FIFA Soccer 97 (USA)
      @"SLES-00914" : @8, // FIFA - Road to World Cup 98 (Europe) (En,Fr,De,Es,Nl,Sv)
      @"SLES-00915" : @8, // FIFA - En Route pour la Coupe du Monde 98 (France) (En,Fr,De,Es,Nl,Sv)
      @"SLES-00916" : @8, // FIFA - Die WM-Qualifikation 98 (Germany) (En,Fr,De,Es,Nl,Sv)
      @"SLES-00917" : @8, // FIFA - Road to World Cup 98 (Italy)
      @"SLPS-01383" : @8, // FIFA - Road to World Cup 98 (Japan)
      @"SLES-00918" : @8, // FIFA - Rumbo al Mundial 98 (Spain) (En,Fr,De,Es,Nl,Sv)
      @"SLUS-00520" : @8, // FIFA - Road to World Cup 98 (USA) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01584" : @8, // FIFA 99 (Europe) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01585" : @8, // FIFA 99 (France) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01586" : @8, // FIFA 99 (Germany) (En,Fr,De,Es,Nl,Sv)
      @"SLES-01587" : @8, // FIFA 99 (Italy)
      @"SLPS-02309" : @8, // FIFA 99 - Europe League Soccer (Japan)
      @"SLES-01588" : @8, // FIFA 99 (Spain) (En,Fr,De,Es,Nl,Sv)
      @"SLUS-00782" : @8, // FIFA 99 (USA)
      @"SLES-02315" : @8, // FIFA 2000 (Europe) (En,De,Es,Nl,Sv) (v1.0) / (v1.1)
      @"SLES-02316" : @8, // FIFA 2000 (France)
      @"SLES-02317" : @8, // FIFA 2000 (Germany) (En,De,Es,Nl,Sv)
      @"SLES-02320" : @8, // FIFA 2000 (Greece)
      @"SLES-02319" : @8, // FIFA 2000 (Italy)
      @"SLPS-02675" : @8, // FIFA 2000 - Europe League Soccer (Japan)
      @"SLES-02318" : @8, // FIFA 2000 (Spain) (En,De,Es,Nl,Sv)
      @"SLUS-00994" : @8, // FIFA 2000 - Major League Soccer (USA) (En,De,Es,Nl,Sv)
      @"SLES-03140" : @8, // FIFA 2001 (Europe) (En,De,Es,Nl,Sv)
      @"SLES-03141" : @8, // FIFA 2001 (France)
      @"SLES-03142" : @8, // FIFA 2001 (Germany) (En,De,Es,Nl,Sv)
      @"SLES-03143" : @8, // FIFA 2001 (Greece)
      @"SLES-03145" : @8, // FIFA 2001 (Italy)
      @"SLES-03146" : @8, // FIFA 2001 (Spain) (En,De,Es,Nl,Sv)
      @"SLUS-01262" : @8, // FIFA 2001 (USA)
      @"SLES-03666" : @8, // FIFA Football 2002 (Europe) (En,De,Es,Nl,Sv)
      @"SLES-03668" : @8, // FIFA Football 2002 (France)
      @"SLES-03669" : @8, // FIFA Football 2002 (Germany) (En,De,Es,Nl,Sv)
      @"SLES-03671" : @8, // FIFA Football 2002 (Italy)
      @"SLES-03672" : @8, // FIFA Football 2002 (Spain) (En,De,Es,Nl,Sv)
      @"SLUS-01408" : @8, // FIFA Soccer 2002 (USA) (En,Es)
      @"SLES-03977" : @8, // FIFA Football 2003 (Europe) (En,Nl,Sv)
      @"SLES-03978" : @8, // FIFA Football 2003 (France)
      @"SLES-03979" : @8, // FIFA Football 2003 (Germany)
      @"SLES-03980" : @8, // FIFA Football 2003 (Italy)
      @"SLES-03981" : @8, // FIFA Football 2003 (Spain)
      @"SLUS-01504" : @8, // FIFA Soccer 2003 (USA)
      @"SLES-04115" : @8, // FIFA Football 2004 (Europe) (En,Nl,Sv)
      @"SLES-04116" : @8, // FIFA Football 2004 (France)
      @"SLES-04117" : @8, // FIFA Football 2004 (Germany)
      @"SLES-04119" : @8, // FIFA Football 2004 (Italy)
      @"SLES-04118" : @8, // FIFA Football 2004 (Spain)
      @"SLUS-01578" : @8, // FIFA Soccer 2004 (USA) (En,Es)
      @"SLES-04165" : @8, // FIFA Football 2005 (Europe) (En,Nl)
      @"SLES-04166" : @8, // FIFA Football 2005 (France)
      @"SLES-04168" : @8, // FIFA Football 2005 (Germany)
      @"SLES-04167" : @8, // FIFA Football 2005 (Italy)
      @"SLES-04169" : @8, // FIFA Football 2005 (Spain)
      @"SLUS-01585" : @8, // FIFA Soccer 2005 (USA) (En,Es)
      @"SLUS-01129" : @8, // FoxKids.com - Micro Maniacs Racing (USA)
      @"SLES-03084" : @8, // Inspector Gadget - Gadget's Crazy Maze (Europe) (En,Fr,De,Es,It,Nl)
      @"SLUS-01267" : @8, // Inspector Gadget - Gadget's Crazy Maze (USA) (En,Fr,De,Es,It,Nl)
      @"SLUS-00500" : @8, // Jimmy Johnson's VR Football '98 (USA)
      @"SLES-00436" : @8, // Madden NFL 97 (Europe)
      @"SLUS-00018" : @8, // Madden NFL 97 (USA)
      @"SLES-00904" : @8, // Madden NFL 98 (Europe)
      @"SLUS-00516" : @8, // Madden NFL 98 (USA) / (Alt)
      @"SLES-01427" : @8, // Madden NFL 99 (Europe)
      @"SLUS-00729" : @8, // Madden NFL 99 (USA)
      @"SLES-02192" : @8, // Madden NFL 2000 (Europe)
      @"SLUS-00961" : @8, // Madden NFL 2000 (USA)
      @"SLES-03067" : @8, // Madden NFL 2001 (Europe)
      @"SLUS-01241" : @8, // Madden NFL 2001 (USA)
      @"SLUS-01402" : @8, // Madden NFL 2002 (USA)
      @"SLUS-01482" : @8, // Madden NFL 2003 (USA)
      @"SLUS-01570" : @8, // Madden NFL 2004 (USA)
      @"SLUS-01584" : @8, // Madden NFL 2005 (USA)
      @"SLUS-00526" : @8, // March Madness '98 (USA)
      @"SLUS-00559" : @8, // Micro Machines V3 (USA)
      @"SLUS-00507" : @8, // Monopoly (USA)
      @"SLUS-01178" : @8, // Monster Rancher Battle Card - Episode II (USA)
      @"SLES-02299" : @8, // NBA Basketball 2000 (Europe) (En,Fr,De,Es,It)
      @"SLUS-00926" : @8, // NBA Basketball 2000 (USA)
      @"SLES-01003" : @8, // NBA Fastbreak '98 (Europe)
      @"SLUS-00492" : @8, // NBA Fastbreak '98 (USA)
      @"SLES-00171" : @8, // NBA in the Zone (Europe)
      @"SLPS-00188" : @8, // NBA Power Dunkers (Japan)
      @"SLUS-00048" : @8, // NBA in the Zone (USA)
      @"SLES-00560" : @8, // NBA in the Zone 2 (Europe)
      @"SLPM-86011" : @8, // NBA Power Dunkers 2 (Japan)
      @"SLUS-00294" : @8, // NBA in the Zone 2 (USA)
      @"SLES-00882" : @8, // NBA Pro 98 (Europe)
      @"SLPM-86060" : @8, // NBA Power Dunkers 3 (Japan)
      @"SLUS-00445" : @8, // NBA in the Zone '98 (USA) (v1.0) / (v1.1)
      @"SLES-01970" : @8, // NBA Pro 99 (Europe)
      @"SLPM-86176" : @8, // NBA Power Dunkers 4 (Japan)
      @"SLUS-00791" : @8, // NBA in the Zone '99 (USA)
      @"SLES-02513" : @8, // NBA in the Zone 2000 (Europe)
      @"SLPM-86397" : @8, // NBA Power Dunkers 5 (Japan)
      @"SLUS-01028" : @8, // NBA in the Zone 2000 (USA)
      @"SLES-00225" : @8, // NBA Live 96 (Europe)
      @"SLPS-00389" : @8, // NBA Live 96 (Japan)
      @"SLUS-00060" : @8, // NBA Live 96 (USA)
      @"SLES-00517" : @8, // NBA Live 97 (Europe) (En,Fr,De)
      @"SLPS-00736" : @8, // NBA Live 97 (Japan)
      @"SLUS-00267" : @8, // NBA Live 97 (USA)
      @"SLES-00906" : @8, // NBA Live 98 (Europe) (En,Es,It)
      @"SLES-00952" : @8, // NBA Live 98 (Germany)
      @"SLPS-01296" : @8, // NBA Live 98 (Japan)
      @"SLUS-00523" : @8, // NBA Live 98 (USA)
      @"SLES-01446" : @8, // NBA Live 99 (Europe)
      @"SLES-01455" : @8, // NBA Live 99 (Germany)
      @"SLES-01456" : @8, // NBA Live 99 (Italy)
      @"SLPS-02033" : @8, // NBA Live 99 (Japan)
      @"SLES-01457" : @8, // NBA Live 99 (Spain)
      @"SLUS-00736" : @8, // NBA Live 99 (USA)
      @"SLES-02358" : @8, // NBA Live 2000 (Europe)
      @"SLES-02360" : @8, // NBA Live 2000 (Germany)
      @"SLES-02361" : @8, // NBA Live 2000 (Italy)
      @"SLPS-02603" : @8, // NBA Live 2000 (Japan)
      @"SLES-02362" : @8, // NBA Live 2000 (Spain)
      @"SLUS-00998" : @8, // NBA Live 2000 (USA)
      @"SLES-03128" : @8, // NBA Live 2001 (Europe)
      @"SLES-03129" : @8, // NBA Live 2001 (France)
      @"SLES-03130" : @8, // NBA Live 2001 (Germany)
      @"SLES-03131" : @8, // NBA Live 2001 (Italy)
      @"SLES-03132" : @8, // NBA Live 2001 (Spain)
      @"SLUS-01271" : @8, // NBA Live 2001 (USA)
      @"SLES-03718" : @8, // NBA Live 2002 (Europe)
      @"SLES-03719" : @8, // NBA Live 2002 (France)
      @"SLES-03720" : @8, // NBA Live 2002 (Germany)
      @"SLES-03721" : @8, // NBA Live 2002 (Italy)
      @"SLES-03722" : @8, // NBA Live 2002 (Spain)
      @"SLUS-01416" : @8, // NBA Live 2002 (USA)
      @"SLES-03982" : @8, // NBA Live 2003 (Europe)
      @"SLES-03969" : @8, // NBA Live 2003 (France)
      @"SLES-03968" : @8, // NBA Live 2003 (Germany)
      @"SLES-03970" : @8, // NBA Live 2003 (Italy)
      @"SLES-03971" : @8, // NBA Live 2003 (Spain)
      @"SLUS-01483" : @8, // NBA Live 2003 (USA)
      @"SCES-00067" : @8, // Total NBA '96 (Europe)
      @"SIPS-60008" : @8, // Total NBA '96 (Japan)
      @"SCUS-94500" : @8, // NBA Shoot Out (USA)
      @"SCES-00623" : @8, // Total NBA '97 (Europe)
      @"SIPS-60015" : @8, // Total NBA '97 (Japan)
      @"SCUS-94552" : @8, // NBA Shoot Out '97 (USA)
      @"SCES-01079" : @8, // Total NBA 98 (Europe)
      @"SCUS-94171" : @8, // NBA ShootOut 98 (USA)
      @"SCUS-94561" : @8, // NBA ShootOut 2000 (USA)
      @"SCUS-94581" : @8, // NBA ShootOut 2001 (USA)
      @"SCUS-94641" : @8, // NBA ShootOut 2002 (USA)
      @"SCUS-94673" : @8, // NBA ShootOut 2003 (USA)
      @"SCUS-94691" : @8, // NBA ShootOut 2004 (USA)
      @"SLUS-00142" : @8, // NCAA Basketball Final Four 97 (USA)
      @"SCUS-94264" : @8, // NCAA Final Four 99 (USA)
      @"SCUS-94562" : @8, // NCAA Final Four 2000 (USA)
      @"SCUS-94579" : @8, // NCAA Final Four 2001 (USA)
      @"SLUS-00514" : @8, // NCAA Football 98 (USA)
      @"SLUS-00688" : @8, // NCAA Football 99 (USA)
      @"SLUS-00932" : @8, // NCAA Football 2000 (USA) (v1.0) / (v1.1)
      @"SLUS-01219" : @8, // NCAA Football 2001 (USA)
      @"SCUS-94509" : @8, // NCAA Football GameBreaker (USA)
      @"SCUS-94172" : @8, // NCAA GameBreaker 98 (USA)
      @"SCUS-94246" : @8, // NCAA GameBreaker 99 (USA)
      @"SCUS-94557" : @8, // NCAA GameBreaker 2000 (USA)
      @"SCUS-94573" : @8, // NCAA GameBreaker 2001 (USA)
      @"SLUS-00805" : @8, // NCAA March Madness 99 (USA)
      @"SLUS-01023" : @8, // NCAA March Madness 2000 (USA)
      @"SLUS-01320" : @8, // NCAA March Madness 2001 (USA)
      @"SCES-00219" : @8, // NFL GameDay (Europe)
      @"SCUS-94505" : @8, // NFL GameDay (USA)
      @"SCUS-94510" : @8, // NFL GameDay 97 (USA)
      @"SCUS-94173" : @8, // NFL GameDay 98 (USA)
      @"SCUS-94234" : @8, // NFL GameDay 99 (USA) (v1.0) / (v1.1)
      @"SCUS-94556" : @8, // NFL GameDay 2000 (USA)
      @"SCUS-94575" : @8, // NFL GameDay 2001 (USA)
      @"SCUS-94639" : @8, // NFL GameDay 2002 (USA)
      @"SCUS-94665" : @8, // NFL GameDay 2003 (USA)
      @"SCUS-94690" : @8, // NFL GameDay 2004 (USA)
      @"SCUS-94695" : @8, // NFL GameDay 2005 (USA)
      @"SLES-00449" : @8, // NFL Quarterback Club 97 (Europe)
      @"SLUS-00011" : @8, // NFL Quarterback Club 97 (USA)
      @"SCUS-94420" : @8, // NFL Xtreme 2 (USA)
      @"SLES-00492" : @8, // NHL 97 (Europe)
      @"SLES-00533" : @8, // NHL 97 (Germany)
      @"SLPS-00861" : @8, // NHL 97 (Japan)
      @"SLUS-00030" : @8, // NHL 97 (USA)
      @"SLES-00907" : @8, // NHL 98 (Europe) (En,Sv,Fi)
      @"SLES-00512" : @8, // NHL 98 (Germany)
      @"SLUS-00519" : @8, // NHL 98 (USA)
      @"SLES-01445" : @8, // NHL 99 (Europe) (En,Fr,Sv,Fi)
      @"SLES-01458" : @8, // NHL 99 (Germany)
      @"SLUS-00735" : @8, // NHL 99 (USA)
      @"SLES-02225" : @8, // NHL 2000 (Europe) (En,Sv,Fi)
      @"SLES-02227" : @8, // NHL 2000 (Germany)
      @"SLUS-00965" : @8, // NHL 2000 (USA)
      @"SLES-03139" : @8, // NHL 2001 (Europe) (En,Sv,Fi)
      @"SLES-03154" : @8, // NHL 2001 (Germany)
      @"SLUS-01264" : @8, // NHL 2001 (USA)
      @"SLES-02514" : @8, // NHL Blades of Steel 2000 (Europe)
      @"SLPM-86193" : @8, // NHL Blades of Steel 2000 (Japan)
      @"SLUS-00825" : @8, // NHL Blades of Steel 2000 (USA)
      @"SLES-00624" : @8, // NHL Breakaway 98 (Europe)
      @"SLUS-00391" : @8, // NHL Breakaway 98 (USA)
      @"SLES-02298" : @8, // NHL Championship 2000 (Europe) (En,Fr,De,Sv)
      @"SLUS-00925" : @8, // NHL Championship 2000 (USA)
      @"SCES-00392" : @8, // NHL Face Off '97 (Europe)
      @"SIPS-60018" : @8, // NHL PowerRink '97 (Japan)
      @"SCUS-94550" : @8, // NHL Face Off '97 (USA)
      @"SCES-01022" : @8, // NHL FaceOff 98 (Europe)
      @"SCUS-94174" : @8, // NHL FaceOff 98 (USA)
      @"SCES-01736" : @8, // NHL FaceOff 99 (Europe)
      @"SCUS-94235" : @8, // NHL FaceOff 99 (USA)
      @"SCES-02451" : @8, // NHL FaceOff 2000 (Europe)
      @"SCUS-94558" : @8, // NHL FaceOff 2000 (USA)
      @"SCUS-94577" : @8, // NHL FaceOff 2001 (USA)
      @"SLES-00418" : @8, // NHL Powerplay 98 (Europe) (En,Fr,De)
      @"SLUS-00528" : @8, // NHL Powerplay 98 (USA) (En,Fr,De)
      @"SLES-00110" : @8, // Olympic Games (Europe) (En,Fr,De,Es,It)
      @"SLPS-00465" : @8, // Atlanta Olympics '96
      @"SLUS-00148" : @8, // Olympic Summer Games (USA)
      @"SLES-01559" : @8, // Pro 18 - World Tour Golf (Europe) (En,Fr,De,Es,It,Sv)
      @"SLUS-00817" : @8, // Pro 18 - World Tour Golf (USA)
      @"SLES-00472" : @8, // Riot (Europe)
      @"SCUS-94551" : @8, // Professional Underground League of Pain (USA)
      @"SLES-01203" : @8, // Puma Street Soccer (Europe) (En,Fr,De,It)
      @"SLES-01436" : @8, // Rival Schools - United by Fate (Europe) (Disc 1) (Evolution Disc)
      @"SLES-11436" : @8, // Rival Schools - United by Fate (Europe) (Disc 2) (Arcade Disc)
      @"SLPS-01240" : @8, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 1) (Evolution Disc)
      @"SLPS-01241" : @8, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 2) (Arcade Disc)
      @"SLPS-02120" : @8, // Shiritsu Justice Gakuen - Nekketsu Seishun Nikki 2 (Japan)
      @"SLES-01658" : @8, // Shaolin (Europe)
      @"SLPS-02168" : @8, // Lord of Fist (Japan)
      @"SLES-00296" : @8, // Street Racer (Europe)
      @"SLPS-00610" : @8, // Street Racer Extra (Japan)
      @"SLUS-00099" : @8, // Street Racer (USA)
      @"SLES-02857" : @8, // Sydney 2000 (Europe)
      @"SLES-02858" : @8, // Sydney 2000 (France)
      @"SLES-02859" : @8, // Sydney 2000 (Germany)
      @"SLPM-86626" : @8, // Sydney 2000 (Japan)
      @"SLES-02861" : @8, // Sydney 2000 (Spain)
      @"SLUS-01177" : @8, // Sydney 2000 (USA)
      @"SCES-01700" : @8, // This Is Football (Europe)
      @"SCES-01882" : @8, // This Is Football (Europe) (Fr,Nl)
      @"SCES-01701" : @8, // Monde des Bleus, Le - Le jeu officiel de l'equipe de France (France)
      @"SCES-01702" : @8, // Fussball Live (Germany)
      @"SCES-01703" : @8, // This Is Football (Italy)
      @"SCES-01704" : @8, // Esto es Futbol (Spain)
      @"SCES-03070" : @8, // This Is Football 2 (Europe)
      @"SCES-03073" : @8, // Monde des Bleus 2, Le (France)
      @"SCES-03074" : @8, // Fussball Live 2 (Germany)
      @"SCES-03075" : @8, // This Is Football 2 (Italy)
      @"SCES-03072" : @8, // This Is Football 2 (Netherlands)
      @"SCES-03076" : @8, // Esto es Futbol 2 (Spain)
      @"SLPS-00682" : @8, // Triple Play 97 (Japan)
      @"SLUS-00237" : @8, // Triple Play 97 (USA)
      @"SLPS-00887" : @8, // Triple Play 98 (Japan)
      @"SLUS-00465" : @8, // Triple Play 98 (USA)
      @"SLUS-00618" : @8, // Triple Play 99 (USA) (En,Es)
      @"SLES-02577" : @8, // UEFA Champions League - Season 1999-2000 (Europe)
      @"SLES-02578" : @8, // UEFA Champions League - Season 1999-2000 (France)
      @"SLES-02579" : @8, // UEFA Champions League - Season 1999-2000 (Germany)
      @"SLES-02580" : @8, // UEFA Champions League - Season 1999-2000 (Italy)
      @"SLES-03262" : @8, // UEFA Champions League - Season 2000-2001 (Europe)
      @"SLES-03281" : @8, // UEFA Champions League - Season 2000-2001 (Germany)
      @"SLES-02704" : @8, // UEFA Euro 2000 (Europe)
      @"SLES-02705" : @8, // UEFA Euro 2000 (France)
      @"SLES-02706" : @8, // UEFA Euro 2000 (Germany)
      @"SLES-02707" : @8, // UEFA Euro 2000 (Italy)
      @"SLES-01265" : @8, // World Cup 98 (Europe) (En,Fr,De,Es,Nl,Sv,Da)
      @"SLES-01266" : @8, // Coupe du Monde 98 (France)
      @"SLES-01267" : @8, // Frankreich 98 - Die Fussball-WM (Germany) (En,Fr,De,Es,Nl,Sv,Da)
      @"SLES-01268" : @8, // World Cup 98 - Coppa del Mondo (Italy)
      @"SLPS-01719" : @8, // FIFA World Cup 98 - France 98 Soushuuhen (Japan)
      @"SLUS-00644" : @8, // World Cup 98 (USA)
      };

    // 5-player games requiring Multitap on port 2 instead of port 1
    NSArray *multiTap5PlayerPort2 =
    @[
      @"SLES-01893", // Bomberman (Europe)
      @"SLPS-01717", // Bomberman (Japan)
      @"SLUS-01189", // Bomberman - Party Edition (USA)
      ];

    // PlayStation multi-disc games (mostly complete, few missing obscure undumped/unverified JP releases)
    NSDictionary *multiDiscGames =
    @{
      @"SLPS-00071" : @2, // 3x3 Eyes - Kyuusei Koushu (Japan) (Disc 1)
      @"SLPS-00072" : @2, // 3x3 Eyes - Kyuusei Koushu (Japan) (Disc 2)
      @"SLPS-01497" : @3, // 3x3 Eyes - Tenrinou Genmu (Japan) (Disc 1)
      @"SLPS-01498" : @3, // 3x3 Eyes - Tenrinou Genmu (Japan) (Disc 2)
      @"SLPS-01499" : @3, // 3x3 Eyes - Tenrinou Genmu (Japan) (Disc 3)
      @"SLPS-01995" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 1)
      @"SLPS-01996" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 2)
      @"SLPS-01997" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 3)
      @"SLPS-01998" : @4, // 70's Robot Anime - Geppy-X - The Super Boosted Armor (Japan) (Disc 4)
      @"SCES-02153" : @2, // A Sangre Fria (Spain) (Disc 1)
      @"SCES-12153" : @2, // A Sangre Fria (Spain) (Disc 2)
      @"SCES-02152" : @2, // A Sangue Freddo (Italy) (Disc 1)
      @"SCES-12152" : @2, // A Sangue Freddo (Italy) (Disc 2)
      @"SLPS-02095" : @2, // Abe '99 (Japan) (Disc 1)
      @"SLPS-02096" : @2, // Abe '99 (Japan) (Disc 2)
      @"SLPS-02020" : @2, // Ace Combat 3 - Electrosphere (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPS-02021" : @2, // Ace Combat 3 - Electrosphere (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCPS-10131" : @2, // Aconcagua (Japan) (Disc 1)
      @"SCPS-10132" : @2, // Aconcagua (Japan) (Disc 2)
      @"SLPM-86254" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 1)
      @"SLPM-86255" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 2)
      @"SLPM-86256" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 3)
      @"SLPM-86257" : @4, // Aitakute... Your Smiles in My Heart (Japan) (Disc 4)
      @"SLPS-01527" : @3, // Alive (Japan) (Disc 1)
      @"SLPS-01528" : @3, // Alive (Japan) (Disc 2)
      @"SLPS-01529" : @3, // Alive (Japan) (Disc 3)
      @"SLES-04107" : @2, // All Star Action (Europe) (Disc 1)
      @"SLES-14107" : @2, // All Star Action (Europe) (Disc 2)
      @"SLPS-01187" : @3, // Alnam no Tsubasa - Shoujin no Sora no Kanata e (Japan) (Disc 1)
      @"SLPS-01188" : @3, // Alnam no Tsubasa - Shoujin no Sora no Kanata e (Japan) (Disc 2)
      @"SLPS-01189" : @3, // Alnam no Tsubasa - Shoujin no Sora no Kanata e (Japan) (Disc 3)
      @"SLES-02801" : @2, // Alone in the Dark - The New Nightmare (Europe) (Disc 1)
      @"SLES-12801" : @2, // Alone in the Dark - The New Nightmare (Europe) (Disc 2)
      @"SLES-02802" : @2, // Alone in the Dark - The New Nightmare (France) (Disc 1)
      @"SLES-12802" : @2, // Alone in the Dark - The New Nightmare (France) (Disc 2)
      @"SLES-02803" : @2, // Alone in the Dark - The New Nightmare (Germany) (Disc 1)
      @"SLES-12803" : @2, // Alone in the Dark - The New Nightmare (Germany) (Disc 2)
      @"SLES-02805" : @2, // Alone in the Dark - The New Nightmare (Italy) (Disc 1)
      @"SLES-12805" : @2, // Alone in the Dark - The New Nightmare (Italy) (Disc 2)
      @"SLES-02804" : @2, // Alone in the Dark - The New Nightmare (Spain) (Disc 1)
      @"SLES-12804" : @2, // Alone in the Dark - The New Nightmare (Spain) (Disc 2)
      @"SLUS-01201" : @2, // Alone in the Dark - The New Nightmare (USA) (Disc 1)
      @"SLUS-01377" : @2, // Alone in the Dark - The New Nightmare (USA) (Disc 2)
      @"SLES-02348" : @2, // Amerzone - Das Testament des Forschungsreisenden (Germany) (Disc 1)
      @"SLES-12348" : @2, // Amerzone - Das Testament des Forschungsreisenden (Germany) (Disc 2)
      @"SLES-02349" : @2, // Amerzone - El Legado del Explorador (Spain) (Disc 1)
      @"SLES-12349" : @2, // Amerzone - El Legado del Explorador (Spain) (Disc 2)
      @"SLES-02350" : @2, // Amerzone - Il Testamento dell'Esploratore (Italy) (Disc 1)
      @"SLES-12350" : @2, // Amerzone - Il Testamento dell'Esploratore (Italy) (Disc 2)
      @"SLES-02347" : @2, // Amerzone - The Explorer's Legacy (Europe) (Disc 1)
      @"SLES-12347" : @2, // Amerzone - The Explorer's Legacy (Europe) (Disc 2)
      @"SLES-02346" : @2, // Amerzone, L' (France) (Disc 1)
      @"SLES-12346" : @2, // Amerzone, L' (France) (Disc 2)
      @"SLPS-01108" : @2, // Ancient Roman - Power of Dark Side (Japan) (Disc 1)
      @"SLPS-01109" : @2, // Ancient Roman - Power of Dark Side (Japan) (Disc 2)
      @"SLPS-01830" : @2, // Animetic Story Game 1 - Card Captor Sakura (Japan) (Disc 1)
      @"SLPS-01831" : @2, // Animetic Story Game 1 - Card Captor Sakura (Japan) (Disc 2)
      @"SLPS-01068" : @2, // Ankh - Tutankhamen no Nazo (Japan) (Disc 1)
      @"SLPS-01069" : @2, // Ankh - Tutankhamen no Nazo (Japan) (Disc 2)
      @"SLPS-02940" : @2, // Ao no Rokugou - Antarctica (Japan) (Disc 1)
      @"SLPS-02941" : @2, // Ao no Rokugou - Antarctica (Japan) (Disc 2)
      //@"SCPS-10040" : @2, // Arc the Lad - Monster Game with Casino Game (Japan) (Disc 1) (Monster Game)
      //@"SCPS-10041" : @2, // Arc the Lad - Monster Game with Casino Game (Japan) (Disc 2) (Casino Game)
      @"SLUS-01253" : @2, // Arc the Lad Collection - Arc the Lad III (USA) (Disc 1)
      @"SLUS-01254" : @2, // Arc the Lad Collection - Arc the Lad III (USA) (Disc 2)
      @"SCPS-10106" : @2, // Arc the Lad III (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SCPS-10107" : @2, // Arc the Lad III (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01855" : @2, // Armored Core - Master of Arena (Japan) (Disc 1) (v1.0)
      @"SLPS-01856" : @2, // Armored Core - Master of Arena (Japan) (Disc 2) (v1.0)
      @"SLPS-91444" : @2, // Armored Core - Master of Arena (Japan) (Disc 1) (v1.1)
      @"SLPS-91445" : @2, // Armored Core - Master of Arena (Japan) (Disc 2) (v1.1)
      @"SLUS-01030" : @2, // Armored Core - Master of Arena (USA) (Disc 1)
      @"SLUS-01081" : @2, // Armored Core - Master of Arena (USA) (Disc 2)
      @"SLPM-86088" : @2, // Astronoka (Japan) (Disc 1)
      @"SLPM-86089" : @2, // Astronoka (Japan) (Disc 2)
      @"SLPM-86185" : @3, // Athena - Awakening from the Ordinary Life (Japan) (Disc 1)
      @"SLPM-86186" : @3, // Athena - Awakening from the Ordinary Life (Japan) (Disc 2)
      @"SLPM-86187" : @3, // Athena - Awakening from the Ordinary Life (Japan) (Disc 3)
      @"SLES-01603" : @3, // Atlantis - Das sagenhafte Abenteuer (Germany) (Disc 1)
      @"SLES-11603" : @3, // Atlantis - Das sagenhafte Abenteuer (Germany) (Disc 2)
      @"SLES-21603" : @3, // Atlantis - Das sagenhafte Abenteuer (Germany) (Disc 3)
      @"SLES-01602" : @3, // Atlantis - Secrets d'Un Monde Oublie (France) (Disc 1)
      @"SLES-11602" : @3, // Atlantis - Secrets d'Un Monde Oublie (France) (Disc 2)
      @"SLES-21602" : @3, // Atlantis - Secrets d'Un Monde Oublie (France) (Disc 3)
      @"SLES-01604" : @3, // Atlantis - Segreti d'Un Mondo Perduto (Italy) (Disc 1)
      @"SLES-11604" : @3, // Atlantis - Segreti d'Un Mondo Perduto (Italy) (Disc 2)
      @"SLES-21604" : @3, // Atlantis - Segreti d'Un Mondo Perduto (Italy) (Disc 3)
      @"SLES-01291" : @3, // Atlantis - The Lost Tales (Europe) (Disc 1)
      @"SLES-11291" : @3, // Atlantis - The Lost Tales (Europe) (Disc 2)
      @"SLES-21291" : @3, // Atlantis - The Lost Tales (Europe) (Disc 3)
      @"SLES-01605" : @3, // Atlantis - The Lost Tales (Europe) (En,Es,Nl,Sv) (Disc 1)
      @"SLES-11605" : @3, // Atlantis - The Lost Tales (Europe) (En,Es,Nl,Sv) (Disc 2)
      @"SLES-21605" : @3, // Atlantis - The Lost Tales (Europe) (En,Es,Nl,Sv) (Disc 3)
      @"SLPS-00946" : @2, // Ayakashi Ninden Kunoichiban (Japan) (Disc 1)
      @"SLPS-00947" : @2, // Ayakashi Ninden Kunoichiban (Japan) (Disc 2)
      @"SLPS-01003" : @3, // B Senjou no Alice - Alice on Borderlines (Japan) (Disc 1)
      @"SLPS-01004" : @3, // B Senjou no Alice - Alice on Borderlines (Japan) (Disc 2)
      @"SLPS-01005" : @3, // B Senjou no Alice - Alice on Borderlines (Japan) (Disc 3)
      @"SLPS-01446" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Hishou Hen 'Uragiri no Senjou' (Japan) (Disc 1)
      @"SLPS-01447" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Hishou Hen 'Uragiri no Senjou' (Japan) (Disc 2)
      @"SLPS-01217" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Kakusei Hen 'Guiner Tensei' (Japan) (Disc 1)
      @"SLPS-01218" : @2, // Back Guiner - Yomigaeru Yuusha Tachi - Kakusei Hen 'Guiner Tensei' (Japan) (Disc 2)
      @"SLPM-86126" : @2, // Beat Mania (Japan) (Disc 1) (Arcade)
      @"SLPM-86127" : @2, // Beat Mania (Japan) (Disc 2) (Append)
      @"SLPS-01510" : @2, // Biohazard 2 - Dual Shock Ver. (Japan) (Disc 1) (Leon Hen)
      @"SLPS-01511" : @2, // Biohazard 2 - Dual Shock Ver. (Japan) (Disc 2) (Claire Hen)
      @"SLPS-01222" : @2, // Biohazard 2 (Japan) (Disc 1) (v1.0)
      @"SLPS-01223" : @2, // Biohazard 2 (Japan) (Disc 2) (v1.0)
      @"SLPS-02962" : @2, // Black Matrix + (Japan) (Disc 1)
      @"SLPS-02963" : @2, // Black Matrix + (Japan) (Disc 2)
      @"SLPS-03571" : @2, // Black Matrix 00 (Japan) (Disc 1)
      @"SLPS-03572" : @2, // Black Matrix 00 (Japan) (Disc 2)
      @"SCPS-10094" : @2, // Book of Watermarks, The (Japan) (Disc 1)
      @"SCPS-10095" : @2, // Book of Watermarks, The (Japan) (Disc 2)
      @"SLPS-00514" : @2, // Brain Dead 13 (Japan) (Disc 1)
      @"SLPS-00515" : @2, // Brain Dead 13 (Japan) (Disc 2)
      @"SLUS-00083" : @2, // BrainDead 13 (USA) (Disc 1)
      @"SLUS-00171" : @2, // BrainDead 13 (USA) (Disc 2)
      @"SLPS-02580" : @2, // Brave Saga 2 (Japan) (Disc 1)
      @"SLPS-02581" : @2, // Brave Saga 2 (Japan) (Disc 2)
      @"SLPS-02661" : @2, // Brigandine - Grand Edition (Japan) (Disc 1)
      @"SLPS-02662" : @2, // Brigandine - Grand Edition (Japan) (Disc 2)
      //@"SLPS-01232" : @2, // Bust A Move - Dance & Rhythm Action (Japan) (Disc 1)
      //@"SLPS-01233" : @2, // Bust A Move - Dance & Rhythm Action (Japan) (Disc 2) (Premium CD-ROM)
      //@"SLES-01881" : @4, // Capcom Generations (Europe) (Disc 1) (Wings of Destiny)
      //@"SLES-11881" : @4, // Capcom Generations (Europe) (Disc 2) (Chronicles of Arthur)
      //@"SLES-21881" : @4, // Capcom Generations (Europe) (Disc 3) (The First Generation)
      //@"SLES-31881" : @4, // Capcom Generations (Europe) (Disc 4) (Blazing Guns)
      //@"SLES-02098" : @3, // Capcom Generations (Germany) (Disc 1) (Wings of Destiny)
      //@"SLES-12098" : @3, // Capcom Generations (Germany) (Disc 2) (Chronicles of Arthur)
      //@"SLES-22098" : @3, // Capcom Generations (Germany) (Disc 3) (The First Generation)
      @"SCES-02816" : @2, // Chase the Express - El Expreso de la Muerte (Spain) (Disc 1)
      @"SCES-12816" : @2, // Chase the Express - El Expreso de la Muerte (Spain) (Disc 2)
      @"SCES-02812" : @2, // Chase the Express (Europe) (Disc 1)
      @"SCES-12812" : @2, // Chase the Express (Europe) (Disc 2)
      @"SCES-02813" : @2, // Chase the Express (France) (Disc 1)
      @"SCES-12813" : @2, // Chase the Express (France) (Disc 2)
      @"SCES-02814" : @2, // Chase the Express (Germany) (Disc 1)
      @"SCES-12814" : @2, // Chase the Express (Germany) (Disc 2)
      @"SCES-02815" : @2, // Chase the Express (Italy) (Disc 1)
      @"SCES-12815" : @2, // Chase the Express (Italy) (Disc 2)
      @"SCPS-10109" : @2, // Chase the Express (Japan) (Disc 1)
      @"SCPS-10110" : @2, // Chase the Express (Japan) (Disc 2)
      @"SLPS-01834" : @2, // Chibi Chara Game Ginga Eiyuu Densetsu (Reinhart Version) (Japan) (Disc 1)
      @"SLPS-01835" : @2, // Chibi Chara Game Ginga Eiyuu Densetsu (Reinhart Version) (Japan) (Disc 2)
      @"SLPS-02005" : @2, // Chou Jikuu Yousai Macross - Ai Oboete Imasu ka (Japan) (Disc 1)
      @"SLPS-02006" : @2, // Chou Jikuu Yousai Macross - Ai Oboete Imasu ka (Japan) (Disc 2)
      @"SLES-00165" : @2, // Chronicles of the Sword (Europe) (Disc 1)
      @"SLES-10165" : @2, // Chronicles of the Sword (Europe) (Disc 2)
      @"SLES-00166" : @2, // Chronicles of the Sword (France) (Disc 1)
      @"SLES-10166" : @2, // Chronicles of the Sword (France) (Disc 2)
      @"SLES-00167" : @2, // Chronicles of the Sword (Germany) (Disc 1)
      @"SLES-10167" : @2, // Chronicles of the Sword (Germany) (Disc 2)
      @"SCUS-94700" : @2, // Chronicles of the Sword (USA) (Disc 1)
      @"SCUS-94701" : @2, // Chronicles of the Sword (USA) (Disc 2)
      @"SLPM-87395" : @2, // Chrono Cross (Japan) (Disc 1)
      @"SLPM-87396" : @2, // Chrono Cross (Japan) (Disc 2)
      @"SLUS-01041" : @2, // Chrono Cross (USA) (Disc 1)
      @"SLUS-01080" : @2, // Chrono Cross (USA) (Disc 2)
      @"SLPS-01813" : @3, // Cinema Eikaiwa Series Dai-1-dan - Tengoku ni Ikenai Papa (Japan) (Disc 1) (Joukan)
      @"SLPS-01814" : @3, // Cinema Eikaiwa Series Dai-1-dan - Tengoku ni Ikenai Papa (Japan) (Disc 2) (Chuukan)
      @"SLPS-01815" : @3, // Cinema Eikaiwa Series Dai-1-dan - Tengoku ni Ikenai Papa (Japan) (Disc 3) (Gekan)
      @"SLPS-01872" : @3, // Cinema Eikaiwa Series Dai-2-dan - Interceptor (Japan) (Disc 1) (Joukan)
      @"SLPS-01873" : @3, // Cinema Eikaiwa Series Dai-2-dan - Interceptor (Japan) (Disc 2) (Chuukan)
      @"SLPS-01874" : @3, // Cinema Eikaiwa Series Dai-2-dan - Interceptor (Japan) (Disc 3) (Gekan)
      @"SLPS-01954" : @3, // Cinema Eikaiwa Series Dai-3-dan - Arashigaoka (Japan) (Disc 1) (Joukan)
      @"SLPS-01955" : @3, // Cinema Eikaiwa Series Dai-3-dan - Arashigaoka (Japan) (Disc 2) (Chuukan)
      @"SLPS-01956" : @3, // Cinema Eikaiwa Series Dai-3-dan - Arashigaoka (Japan) (Disc 3) (Gekan)
      @"SLPS-02016" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 1)
      @"SLPS-02017" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 2)
      @"SLPS-02018" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 3)
      @"SLPS-02019" : @4, // Cinema Eikaiwa Series Dai-4-dan - Boy's Life (Japan) (Disc 4)
      @"SLPS-02060" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 1)
      @"SLPS-02061" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 2)
      @"SLPS-02062" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 3)
      @"SLPS-02063" : @4, // Cinema Eikaiwa Series Dai-5-dan - Zombie (Japan) (Disc 4)
      @"SLPM-86241" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 1)
      @"SLPM-86242" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 2)
      @"SLPM-86243" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 3)
      @"SLPM-86244" : @4, // Cinema Eikaiwa Series Dai-6-dan - Ai no Hate ni (Japan) (Disc 4)
      @"SCPS-10077" : @2, // Circadia (Japan) (Disc 1)
      @"SCPS-10078" : @2, // Circadia (Japan) (Disc 2)
      @"SCES-02151" : @2, // Cold Blood (Germany) (Disc 1)
      @"SCES-12151" : @2, // Cold Blood (Germany) (Disc 2)
      @"SLES-00860" : @2, // Colony Wars (Europe) (Disc 1)
      @"SLES-10860" : @2, // Colony Wars (Europe) (Disc 2)
      @"SLES-00861" : @2, // Colony Wars (France) (Disc 1)
      @"SLES-10861" : @2, // Colony Wars (France) (Disc 2)
      @"SLES-00862" : @2, // Colony Wars (Germany) (Disc 1)
      @"SLES-10862" : @2, // Colony Wars (Germany) (Disc 2)
      @"SLES-00863" : @2, // Colony Wars (Italy) (Disc 1)
      @"SLES-10863" : @2, // Colony Wars (Italy) (Disc 2)
      @"SLPS-01403" : @2, // Colony Wars (Japan) (Disc 1)
      @"SLPS-01404" : @2, // Colony Wars (Japan) (Disc 2)
      @"SLES-00864" : @2, // Colony Wars (Spain) (Disc 1)
      @"SLES-10864" : @2, // Colony Wars (Spain) (Disc 2)
      @"SLUS-00543" : @2, // Colony Wars (USA) (Disc 1)
      @"SLUS-00554" : @2, // Colony Wars (USA) (Disc 2)
      //@"SLES-01345" : @2, // Command & Conquer - Alarmstufe Rot - Gegenschlag (Germany) (Disc 1) (Die Alliierten)
      //@"SLES-11345" : @2, // Command & Conquer - Alarmstufe Rot - Gegenschlag (Germany) (Disc 2) (Die Sowjets)
      //@"SLES-01007" : @2, // Command & Conquer - Alarmstufe Rot (Germany) (Disc 1)
      //@"SLES-11007" : @2, // Command & Conquer - Alarmstufe Rot (Germany) (Disc 2)
      //@"SLES-01344" : @2, // Command & Conquer - Alerte Rouge - Mission Tesla (France) (Disc 1) (Allies)
      //@"SLES-11344" : @2, // Command & Conquer - Alerte Rouge - Mission Tesla (France) (Disc 2) (Sovietiques)
      //@"SLES-01006" : @2, // Command & Conquer - Alerte Rouge (France) (Disc 1) (Allies)
      //@"SLES-11006" : @2, // Command & Conquer - Alerte Rouge (France) (Disc 2) (Sovietiques)
      //@"SLES-01343" : @2, // Command & Conquer - Red Alert - Retaliation (Europe) (Disc 1) (Allies)
      //@"SLES-11343" : @2, // Command & Conquer - Red Alert - Retaliation (Europe) (Disc 2) (Soviet)
      //@"SLUS-00665" : @2, // Command & Conquer - Red Alert - Retaliation (USA) (Disc 1) (Allies)
      //@"SLUS-00667" : @2, // Command & Conquer - Red Alert - Retaliation (USA) (Disc 2) (Soviet)
      //@"SLES-00949" : @2, // Command & Conquer - Red Alert (Europe) (Disc 1) (Allies)
      //@"SLES-10949" : @2, // Command & Conquer - Red Alert (Europe) (Disc 2) (Soviet)
      //@"SLUS-00431" : @2, // Command & Conquer - Red Alert (USA) (Disc 1) (Allies)
      //@"SLUS-00485" : @2, // Command & Conquer - Red Alert (USA) (Disc 2) (Soviet)
      //@"SLES-00532" : @2, // Command & Conquer - Teil 1 - Der Tiberiumkonflikt (Germany) (Disc 1) (GDI)
      //@"SLES-10532" : @2, // Command & Conquer - Teil 1 - Der Tiberiumkonflikt (Germany) (Disc 2) (NOD)
      //@"SLES-00530" : @2, // Command & Conquer (Europe) (Disc 1) (GDI)
      //@"SLES-10530" : @2, // Command & Conquer (Europe) (Disc 2) (NOD)
      //@"SLES-00531" : @2, // Command & Conquer (France) (Disc 1) (GDI)
      //@"SLES-10531" : @2, // Command & Conquer (France) (Disc 2) (NOD)
      //@"SLUS-00379" : @2, // Command & Conquer (USA) (Disc 1) (GDI)
      //@"SLUS-00410" : @2, // Command & Conquer (USA) (Disc 2) (NOD)
      //@"SLPS-00976" : @2, // Command & Conquer Complete (Japan) (Disc 1) (GDI)
      //@"SLPS-00977" : @2, // Command & Conquer Complete (Japan) (Disc 2) (NOD)
      @"SLPS-02504" : @2, // Countdown Vampires (Japan) (Disc 1)
      @"SLPS-02505" : @2, // Countdown Vampires (Japan) (Disc 2)
      @"SLUS-00898" : @2, // Countdown Vampires (USA) (Disc 1)
      @"SLUS-01199" : @2, // Countdown Vampires (USA) (Disc 2)
      @"SLUS-01151" : @2, // Covert Ops - Nuclear Dawn (USA) (Disc 1)
      @"SLUS-01157" : @2, // Covert Ops - Nuclear Dawn (USA) (Disc 2)
      @"SLPS-00120" : @2, // Creature Shock (Japan) (Disc 1)
      @"SLPS-00121" : @2, // Creature Shock (Japan) (Disc 2)
      @"SLPM-86280" : @2, // Cross Tantei Monogatari (Japan) (Disc 1)
      @"SLPM-86281" : @2, // Cross Tantei Monogatari (Japan) (Disc 2)
      @"SLPS-01912" : @2, // Cybernetic Empire (Japan) (Disc 1)
      @"SLPS-01913" : @2, // Cybernetic Empire (Japan) (Disc 2)
      @"SLPS-00055" : @3, // Cyberwar (Japan) (Disc 1)
      @"SLPS-00056" : @3, // Cyberwar (Japan) (Disc 2)
      @"SLPS-00057" : @3, // Cyberwar (Japan) (Disc 3)
      @"SLES-00065" : @3, // D (Europe) (Disc 1)
      @"SLES-10065" : @3, // D (Europe) (Disc 2)
      @"SLES-20065" : @3, // D (Europe) (Disc 3)
      @"SLES-00161" : @3, // D (France) (Disc 1)
      @"SLES-10161" : @3, // D (France) (Disc 2)
      @"SLES-20161" : @3, // D (France) (Disc 3)
      @"SLES-00160" : @3, // D (Germany) (Disc 1)
      @"SLES-10160" : @3, // D (Germany) (Disc 2)
      @"SLES-20160" : @3, // D (Germany) (Disc 3)
      @"SLUS-00128" : @3, // D (USA) (Disc 1)
      @"SLUS-00173" : @3, // D (USA) (Disc 2)
      @"SLUS-00174" : @3, // D (USA) (Disc 3)
      @"SLPS-00133" : @3, // D no Shokutaku - Complete Graphics (Japan) (Disc 1)
      @"SLPS-00134" : @3, // D no Shokutaku - Complete Graphics (Japan) (Disc 2)
      @"SLPS-00135" : @3, // D no Shokutaku - Complete Graphics (Japan) (Disc 3)
      @"SLPM-86210" : @3, // Dancing Blade Katte ni Momotenshi II - Tears of Eden (Japan) (Disc 1)
      @"SLPM-86211" : @3, // Dancing Blade Katte ni Momotenshi II - Tears of Eden (Japan) (Disc 2)
      @"SLPM-86212" : @3, // Dancing Blade Katte ni Momotenshi II - Tears of Eden (Japan) (Disc 3)
      @"SLPM-86100" : @3, // Dancing Blade Katte ni Momotenshi! (Japan) (Disc 1)
      @"SLPM-86101" : @3, // Dancing Blade Katte ni Momotenshi! (Japan) (Disc 2)
      @"SLPM-86102" : @3, // Dancing Blade Katte ni Momotenshi! (Japan) (Disc 3)
      @"SCES-02150" : @2, // De Sang Froid (France) (Disc 1)
      @"SCES-12150" : @2, // De Sang Froid (France) (Disc 2)
      @"SLPS-00225" : @3, // DeathMask (Japan) (Disc 1)
      @"SLPS-00226" : @3, // DeathMask (Japan) (Disc 2)
      @"SLPS-00227" : @3, // DeathMask (Japan) (Disc 3)
      @"SLPS-00660" : @2, // Deep Sea Adventure - Kaitei Kyuu Panthalassa no Nazo (Japan) (Disc 1)
      @"SLPS-00661" : @2, // Deep Sea Adventure - Kaitei Kyuu Panthalassa no Nazo (Japan) (Disc 2)
      @"SLPS-01921" : @2, // Devil Summoner - Soul Hackers (Japan) (Disc 1)
      @"SLPS-01922" : @2, // Devil Summoner - Soul Hackers (Japan) (Disc 2)
      @"SLPS-01503" : @2, // Dezaemon Kids! (Japan) (Disc 1)
      @"SLPS-01504" : @2, // Dezaemon Kids! (Japan) (Disc 2)
      @"SLPS-01507" : @3, // Doki Doki Pretty League - Nekketsu Otome Seishunki (Japan) (Disc 1)
      @"SLPS-01508" : @3, // Doki Doki Pretty League - Nekketsu Otome Seishunki (Japan) (Disc 2)
      @"SLPS-01509" : @3, // Doki Doki Pretty League - Nekketsu Otome Seishunki (Japan) (Disc 3)
      @"SLES-02761" : @2, // Dracula - La Risurrezione (Italy) (Disc 1)
      @"SLES-12761" : @2, // Dracula - La Risurrezione (Italy) (Disc 2)
      @"SLES-02762" : @2, // Dracula - Ressurreição (Portugal) (Disc 1)
      @"SLES-12762" : @2, // Dracula - Ressurreição (Portugal) (Disc 2)
      @"SLES-02760" : @2, // Dracula - Resurreccion (Spain) (Disc 1)
      @"SLES-12760" : @2, // Dracula - Resurreccion (Spain) (Disc 2)
      @"SLES-02758" : @2, // Dracula - Resurrection (France) (Disc 1)
      @"SLES-12758" : @2, // Dracula - Resurrection (France) (Disc 2)
      @"SLES-02759" : @2, // Dracula - Resurrection (Germany) (Disc 1)
      @"SLES-12759" : @2, // Dracula - Resurrection (Germany) (Disc 2)
      @"SLUS-01440" : @2, // Dracula - The Last Sanctuary (USA) (Disc 1)
      @"SLUS-01443" : @2, // Dracula - The Last Sanctuary (USA) (Disc 2)
      @"SLES-02757" : @2, // Dracula - The Resurrection (Europe) (Disc 1)
      @"SLES-12757" : @2, // Dracula - The Resurrection (Europe) (Disc 2)
      @"SLUS-01284" : @2, // Dracula - The Resurrection (USA) (Disc 1)
      @"SLUS-01316" : @2, // Dracula - The Resurrection (USA) (Disc 2)
      @"SLES-03350" : @2, // Dracula 2 - Die letzte Zufluchtsstaette (Germany) (Disc 1)
      @"SLES-13350" : @2, // Dracula 2 - Die letzte Zufluchtsstaette (Germany) (Disc 2)
      @"SLES-03352" : @2, // Dracula 2 - El Ultimo Santuario (Spain) (Disc 1)
      @"SLES-13352" : @2, // Dracula 2 - El Ultimo Santuario (Spain) (Disc 2)
      @"SLES-03351" : @2, // Dracula 2 - L'Ultimo Santuario (Italy) (Disc 1)
      @"SLES-13351" : @2, // Dracula 2 - L'Ultimo Santuario (Italy) (Disc 2)
      @"SLES-03349" : @2, // Dracula 2 - Le Dernier Sanctuaire (France) (Disc 1)
      @"SLES-13349" : @2, // Dracula 2 - Le Dernier Sanctuaire (France) (Disc 2)
      @"SLES-03348" : @2, // Dracula 2 - The Last Sanctuary (Europe) (Disc 1)
      @"SLES-13348" : @2, // Dracula 2 - The Last Sanctuary (Europe) (Disc 2)
      @"SLPM-86500" : @2, // Dragon Quest VII - Eden no Senshitachi (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPM-86501" : @2, // Dragon Quest VII - Eden no Senshitachi (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCES-01705" : @2, // Dragon Valor (Europe) (Disc 1)
      @"SCES-11705" : @2, // Dragon Valor (Europe) (Disc 2)
      @"SCES-02565" : @2, // Dragon Valor (France) (Disc 1)
      @"SCES-12565" : @2, // Dragon Valor (France) (Disc 2)
      @"SCES-02566" : @2, // Dragon Valor (Germany) (Disc 1)
      @"SCES-12566" : @2, // Dragon Valor (Germany) (Disc 2)
      @"SCES-02567" : @2, // Dragon Valor (Italy) (Disc 1)
      @"SCES-12567" : @2, // Dragon Valor (Italy) (Disc 2)
      @"SLPS-02190" : @2, // Dragon Valor (Japan) (Disc 1)
      @"SLPS-02191" : @2, // Dragon Valor (Japan) (Disc 2)
      @"SCES-02568" : @2, // Dragon Valor (Spain) (Disc 1)
      @"SCES-12568" : @2, // Dragon Valor (Spain) (Disc 2)
      @"SLUS-01092" : @2, // Dragon Valor (USA) (Disc 1)
      @"SLUS-01164" : @2, // Dragon Valor (USA) (Disc 2)
      @"SLUS-01206" : @2, // Dragon Warrior VII (USA) (Disc 1)
      @"SLUS-01346" : @2, // Dragon Warrior VII (USA) (Disc 2)
      @"SLES-02993" : @2, // Driver 2 - Back on the Streets (Europe) (Disc 1) (v1.0) / (v1.1)
      @"SLES-12993" : @2, // Driver 2 - Back on the Streets (Europe) (Disc 2) (v1.0) / (v1.1)
      @"SLES-02994" : @2, // Driver 2 - Back on the Streets (France) (Disc 1)
      @"SLES-12994" : @2, // Driver 2 - Back on the Streets (France) (Disc 2)
      @"SLES-02995" : @2, // Driver 2 - Back on the Streets (Germany) (Disc 1) (v1.0) / (v1.1)
      @"SLES-12995" : @2, // Driver 2 - Back on the Streets (Germany) (Disc 2) (v1.0) / (v1.1)
      @"SLES-02996" : @2, // Driver 2 - Back on the Streets (Italy) (Disc 1)
      @"SLES-12996" : @2, // Driver 2 - Back on the Streets (Italy) (Disc 2)
      @"SLES-02997" : @2, // Driver 2 - Back on the Streets (Spain) (Disc 1)
      @"SLES-12997" : @2, // Driver 2 - Back on the Streets (Spain) (Disc 2)
      @"SLUS-01161" : @2, // Driver 2 (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-01318" : @2, // Driver 2 (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-00370" : @2, // Dungeon Creator (Japan) (Disc 1)
      @"SLPS-00371" : @2, // Dungeon Creator (Japan) (Disc 2) (Memory Bank Disc)
      @"SLPS-00844" : @2, // Eberouge (Japan) (Disc 1)
      @"SLPS-00845" : @2, // Eberouge (Japan) (Disc 2)
      @"SLPS-03141" : @2, // Eithea (Japan) (Disc 1)
      @"SLPS-03142" : @2, // Eithea (Japan) (Disc 2)
      @"SLPS-00973" : @2, // Elf o Karu Monotachi - Kanzenban (Japan) (Disc 1)
      @"SLPS-00974" : @2, // Elf o Karu Monotachi - Kanzenban (Japan) (Disc 2)
      @"SLPS-01456" : @3, // Elf wo Karu Monotachi II (Japan) (Disc 1)
      @"SLPS-01457" : @3, // Elf wo Karu Monotachi II (Japan) (Disc 2)
      @"SLPS-01458" : @3, // Elf wo Karu Monotachi II (Japan) (Disc 3)
      @"SLPS-00117" : @3, // Emit Value Pack (Japan) (Disc 1) (Vol. 1 - Toki no Maigo)
      @"SLPS-00118" : @3, // Emit Value Pack (Japan) (Disc 2) (Vol. 2 - Inochigake no Tabi)
      @"SLPS-00119" : @3, // Emit Value Pack (Japan) (Disc 3) (Vol. 3 - Watashi ni Sayonara wo)
      @"SLPS-01351" : @2, // Enigma (Japan) (Disc 1)
      @"SLPS-01352" : @2, // Enigma (Japan) (Disc 2)
      @"SLPM-86135" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 1)
      @"SLPM-86136" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 2)
      @"SLPM-86137" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 3)
      @"SLPM-86138" : @4, // Eurasia Express Satsujin Jiken (Japan) (Disc 4)
      @"SLPM-86826" : @3, // Eve - The Fatal Attraction (Japan) (Disc 1)
      @"SLPM-86827" : @3, // Eve - The Fatal Attraction (Japan) (Disc 2)
      @"SLPM-86828" : @3, // Eve - The Fatal Attraction (Japan) (Disc 3)
      @"SLPS-01805" : @3, // Eve - The Lost One (Japan) (Disc 1) (Kyoko Disc) (v1.0)
      @"SLPS-01806" : @3, // Eve - The Lost One (Japan) (Disc 2) (Snake Disc) (v1.0)
      @"SLPS-01807" : @3, // Eve - The Lost One (Japan) (Disc 3) (Lost One Disc) (v1.0)
      @"SLPM-87246" : @3, // Eve - The Lost One (Japan) (Disc 1) (Kyoko Disc) (v1.1)
      @"SLPM-87247" : @3, // Eve - The Lost One (Japan) (Disc 2) (Snake Disc) (v1.1)
      @"SLPM-87248" : @3, // Eve - The Lost One (Japan) (Disc 3) (Lost One Disc) (v1.1)
      @"SLPM-86478" : @3, // Eve Zero (Japan) (Disc 1)
      @"SLPM-86479" : @3, // Eve Zero (Japan) (Disc 2)
      @"SLPM-86480" : @3, // Eve Zero (Japan) (Disc 3)
      @"SLPM-86475" : @3, // Eve Zero (Japan) (Disc 1) (Premium Box)
      @"SLPM-86476" : @3, // Eve Zero (Japan) (Disc 2) (Premium Box)
      @"SLPM-86477" : @3, // Eve Zero (Japan) (Disc 3) (Premium Box)
      @"SLES-03428" : @2, // Evil Dead - Hail to the King (Europe) (Disc 1)
      @"SLES-13428" : @2, // Evil Dead - Hail to the King (Europe) (Disc 2)
      @"SLUS-01072" : @2, // Evil Dead - Hail to the King (USA) (Disc 1)
      @"SLUS-01326" : @2, // Evil Dead - Hail to the King (USA) (Disc 2)
      @"SLES-03485" : @3, // Family Games Compendium (Europe) (Disc 1)
      @"SLES-13485" : @3, // Family Games Compendium (Europe) (Disc 2)
      @"SLES-23485" : @3, // Family Games Compendium (Europe) (En,Fr,De,It) (Disc 3)
      @"SLES-02166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 1)
      @"SLES-12166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 2)
      @"SLES-22166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 3)
      @"SLES-32166" : @4, // Fear Effect (Europe) (En,Es,It) (Disc 4)
      @"SLES-02167" : @4, // Fear Effect (France) (Disc 1)
      @"SLES-12167" : @4, // Fear Effect (France) (Disc 2)
      @"SLES-22167" : @4, // Fear Effect (France) (Disc 3)
      @"SLES-32167" : @4, // Fear Effect (France) (Disc 4)
      @"SLES-02168" : @4, // Fear Effect (Germany) (Disc 1)
      @"SLES-12168" : @4, // Fear Effect (Germany) (Disc 2)
      @"SLES-22168" : @4, // Fear Effect (Germany) (Disc 3)
      @"SLES-32168" : @4, // Fear Effect (Germany) (Disc 4)
      @"SLUS-00920" : @4, // Fear Effect (USA) (Disc 1)
      @"SLUS-01056" : @4, // Fear Effect (USA) (Disc 2)
      @"SLUS-01057" : @4, // Fear Effect (USA) (Disc 3)
      @"SLUS-01058" : @4, // Fear Effect (USA) (Disc 4)
      @"SLES-03386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 1)
      @"SLES-13386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 2)
      @"SLES-23386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 3)
      @"SLES-33386" : @4, // Fear Effect 2 - Retro Helix (Europe) (En,Fr,De) (Disc 4)
      @"SLUS-01266" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-01275" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLUS-01276" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 3) (v1.0) / (v1.1)
      @"SLUS-01277" : @4, // Fear Effect 2 - Retro Helix (USA) (Disc 4) (v1.0) / (v1.1)
      @"SLES-02965" : @4, // Final Fantasy IX (Europe) (Disc 1)
      @"SLES-12965" : @4, // Final Fantasy IX (Europe) (Disc 2)
      @"SLES-22965" : @4, // Final Fantasy IX (Europe) (Disc 3)
      @"SLES-32965" : @4, // Final Fantasy IX (Europe) (Disc 4)
      @"SLES-02966" : @4, // Final Fantasy IX (France) (Disc 1)
      @"SLES-12966" : @4, // Final Fantasy IX (France) (Disc 2)
      @"SLES-22966" : @4, // Final Fantasy IX (France) (Disc 3)
      @"SLES-32966" : @4, // Final Fantasy IX (France) (Disc 4)
      @"SLES-02967" : @4, // Final Fantasy IX (Germany) (Disc 1)
      @"SLES-12967" : @4, // Final Fantasy IX (Germany) (Disc 2)
      @"SLES-22967" : @4, // Final Fantasy IX (Germany) (Disc 3)
      @"SLES-32967" : @4, // Final Fantasy IX (Germany) (Disc 4)
      @"SLES-02968" : @4, // Final Fantasy IX (Italy) (Disc 1)
      @"SLES-12968" : @4, // Final Fantasy IX (Italy) (Disc 2)
      @"SLES-22968" : @4, // Final Fantasy IX (Italy) (Disc 3)
      @"SLES-32968" : @4, // Final Fantasy IX (Italy) (Disc 4)
      @"SLPS-02000" : @4, // Final Fantasy IX (Japan) (Disc 1)
      @"SLPS-02001" : @4, // Final Fantasy IX (Japan) (Disc 2)
      @"SLPS-02002" : @4, // Final Fantasy IX (Japan) (Disc 3)
      @"SLPS-02003" : @4, // Final Fantasy IX (Japan) (Disc 4)
      @"SLES-02969" : @4, // Final Fantasy IX (Spain) (Disc 1)
      @"SLES-12969" : @4, // Final Fantasy IX (Spain) (Disc 2)
      @"SLES-22969" : @4, // Final Fantasy IX (Spain) (Disc 3)
      @"SLES-32969" : @4, // Final Fantasy IX (Spain) (Disc 4)
      @"SLUS-01251" : @4, // Final Fantasy IX (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-01295" : @4, // Final Fantasy IX (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLUS-01296" : @4, // Final Fantasy IX (USA) (Disc 3) (v1.0) / (v1.1)
      @"SLUS-01297" : @4, // Final Fantasy IX (USA) (Disc 4) (v1.0) / (v1.1)
      @"SCES-00867" : @3, // Final Fantasy VII (Europe) (Disc 1)
      @"SCES-10867" : @3, // Final Fantasy VII (Europe) (Disc 2)
      @"SCES-20867" : @3, // Final Fantasy VII (Europe) (Disc 3)
      @"SCES-00868" : @3, // Final Fantasy VII (France) (Disc 1)
      @"SCES-10868" : @3, // Final Fantasy VII (France) (Disc 2)
      @"SCES-20868" : @3, // Final Fantasy VII (France) (Disc 3)
      @"SCES-00869" : @3, // Final Fantasy VII (Germany) (Disc 1)
      @"SCES-10869" : @3, // Final Fantasy VII (Germany) (Disc 2)
      @"SCES-20869" : @3, // Final Fantasy VII (Germany) (Disc 3)
      @"SLPS-00700" : @3, // Final Fantasy VII (Japan) (Disc 1)
      @"SLPS-00701" : @3, // Final Fantasy VII (Japan) (Disc 2)
      @"SLPS-00702" : @3, // Final Fantasy VII (Japan) (Disc 3)
      @"SCES-00900" : @3, // Final Fantasy VII (Spain) (Disc 1) (v1.0) / (v1.1)
      @"SCES-10900" : @3, // Final Fantasy VII (Spain) (Disc 2) (v1.0) / (v1.1)
      @"SCES-20900" : @3, // Final Fantasy VII (Spain) (Disc 3) (v1.0) / (v1.1)
      @"SCUS-94163" : @3, // Final Fantasy VII (USA) (Disc 1)
      @"SCUS-94164" : @3, // Final Fantasy VII (USA) (Disc 2)
      @"SCUS-94165" : @3, // Final Fantasy VII (USA) (Disc 3)
      @"SLPS-01057" : @4, // Final Fantasy VII International (Japan) (Disc 1)
      @"SLPS-01058" : @4, // Final Fantasy VII International (Japan) (Disc 2)
      @"SLPS-01059" : @4, // Final Fantasy VII International (Japan) (Disc 3)
      @"SLPS-01060" : @4, // Final Fantasy VII International (Japan) (Disc 4) (Perfect Guide)
      @"SCES-02080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 1)
      @"SCES-12080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 2)
      @"SCES-22080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 3)
      @"SCES-32080" : @4, // Final Fantasy VIII (Europe, Australia) (Disc 4)
      @"SLES-02081" : @4, // Final Fantasy VIII (France) (Disc 1)
      @"SLES-12081" : @4, // Final Fantasy VIII (France) (Disc 2)
      @"SLES-22081" : @4, // Final Fantasy VIII (France) (Disc 3)
      @"SLES-32081" : @4, // Final Fantasy VIII (France) (Disc 4)
      @"SLES-02082" : @4, // Final Fantasy VIII (Germany) (Disc 1)
      @"SLES-12082" : @4, // Final Fantasy VIII (Germany) (Disc 2)
      @"SLES-22082" : @4, // Final Fantasy VIII (Germany) (Disc 3)
      @"SLES-32082" : @4, // Final Fantasy VIII (Germany) (Disc 4)
      @"SLES-02083" : @4, // Final Fantasy VIII (Italy) (Disc 1)
      @"SLES-12083" : @4, // Final Fantasy VIII (Italy) (Disc 2)
      @"SLES-22083" : @4, // Final Fantasy VIII (Italy) (Disc 3)
      @"SLES-32083" : @4, // Final Fantasy VIII (Italy) (Disc 4)
      @"SLPM-87384" : @4, // Final Fantasy VIII (Japan) (Disc 1)
      @"SLPM-87385" : @4, // Final Fantasy VIII (Japan) (Disc 2)
      @"SLPM-87386" : @4, // Final Fantasy VIII (Japan) (Disc 3)
      @"SLPM-87387" : @4, // Final Fantasy VIII (Japan) (Disc 4)
      @"SLES-02084" : @4, // Final Fantasy VIII (Spain) (Disc 1)
      @"SLES-12084" : @4, // Final Fantasy VIII (Spain) (Disc 2)
      @"SLES-22084" : @4, // Final Fantasy VIII (Spain) (Disc 3)
      @"SLES-32084" : @4, // Final Fantasy VIII (Spain) (Disc 4)
      @"SLUS-00892" : @4, // Final Fantasy VIII (USA) (Disc 1)
      @"SLUS-00908" : @4, // Final Fantasy VIII (USA) (Disc 2)
      @"SLUS-00909" : @4, // Final Fantasy VIII (USA) (Disc 3)
      @"SLUS-00910" : @4, // Final Fantasy VIII (USA) (Disc 4)
      @"SLPS-01708" : @2, // First Kiss Story (Japan) (Disc 1)
      @"SLPS-01709" : @2, // First Kiss Story (Japan) (Disc 2)
      @"SLUS-00101" : @3, // Fox Hunt (USA) (Disc 1)
      @"SLUS-00175" : @3, // Fox Hunt (USA) (Disc 2)
      @"SLUS-00176" : @3, // Fox Hunt (USA) (Disc 3)
      @"SLES-00082" : @2, // G-Police (Europe) (Disc 1)
      @"SLES-10082" : @2, // G-Police (Europe) (Disc 2)
      @"SLES-00853" : @2, // G-Police (France) (Disc 1)
      @"SLES-10853" : @2, // G-Police (France) (Disc 2)
      @"SLES-00854" : @2, // G-Police (Germany) (Disc 1)
      @"SLES-10854" : @2, // G-Police (Germany) (Disc 2)
      @"SLES-00855" : @2, // G-Police (Italy) (Disc 1)
      @"SLES-10855" : @2, // G-Police (Italy) (Disc 2)
      @"SCPS-10065" : @2, // G-Police (Japan) (Disc 1)
      @"SCPS-10066" : @2, // G-Police (Japan) (Disc 2)
      @"SLES-00856" : @2, // G-Police (Spain) (Disc 1)
      @"SLES-10856" : @2, // G-Police (Spain) (Disc 2)
      @"SLUS-00544" : @2, // G-Police (USA) (Disc 1)
      @"SLUS-00556" : @2, // G-Police (USA) (Disc 2)
      @"SLPS-01082" : @4, // Gadget - Past as Future (Japan) (Disc 1)
      @"SLPS-01083" : @4, // Gadget - Past as Future (Japan) (Disc 2)
      @"SLPS-01084" : @4, // Gadget - Past as Future (Japan) (Disc 3)
      @"SLPS-01085" : @4, // Gadget - Past as Future (Japan) (Disc 4)
      @"SLES-02328" : @3, // Galerians (Europe) (Disc 1)
      @"SLES-12328" : @3, // Galerians (Europe) (Disc 2)
      @"SLES-22328" : @3, // Galerians (Europe) (Disc 3)
      @"SLES-02329" : @3, // Galerians (France) (Disc 1)
      @"SLES-12329" : @3, // Galerians (France) (Disc 2)
      @"SLES-22329" : @3, // Galerians (France) (Disc 3)
      @"SLES-02330" : @3, // Galerians (Germany) (Disc 1)
      @"SLES-12330" : @3, // Galerians (Germany) (Disc 2)
      @"SLES-22330" : @3, // Galerians (Germany) (Disc 3)
      @"SLPS-02192" : @3, // Galerians (Japan) (Disc 1)
      @"SLPS-02193" : @3, // Galerians (Japan) (Disc 2)
      @"SLPS-02194" : @3, // Galerians (Japan) (Disc 3)
      @"SLUS-00986" : @3, // Galerians (USA) (Disc 1)
      @"SLUS-01098" : @3, // Galerians (USA) (Disc 2)
      @"SLUS-01099" : @3, // Galerians (USA) (Disc 3)
      @"SLPS-02246" : @2, // Gate Keepers (Japan) (Disc 1)
      @"SLPS-02247" : @2, // Gate Keepers (Japan) (Disc 2)
      @"SLPM-86226" : @2, // Glay - Complete Works (Japan) (Disc 1)
      @"SLPM-86227" : @2, // Glay - Complete Works (Japan) (Disc 2)
      @"SLPS-03061" : @2, // Go Go I Land (Japan) (Disc 1)
      @"SLPS-03062" : @2, // Go Go I Land (Japan) (Disc 2)
      @"SLUS-00319" : @2, // Golden Nugget (USA) (Disc 1)
      @"SLUS-00555" : @2, // Golden Nugget (USA) (Disc 2)
      //@"SCES-02380" : @2, // Gran Turismo 2 (Europe) (En,Fr,De,Es,It) (Disc 1) (Arcade Mode)
      //@"SCES-12380" : @2, // Gran Turismo 2 (Europe) (En,Fr,De,Es,It) (Disc 2) (Gran Turismo Mode)
      //@"SCPS-10116" : @2, // Gran Turismo 2 (Japan) (Disc 1) (Arcade)
      //@"SCPS-10117" : @2, // Gran Turismo 2 (Japan) (Disc 2) (Gran Turismo) (v1.0) / (v1.1)
      @"SLES-02397" : @2, // Grandia (Europe) (Disc 1)
      @"SLES-12397" : @2, // Grandia (Europe) (Disc 2)
      @"SLES-02398" : @2, // Grandia (France) (Disc 1)
      @"SLES-12398" : @2, // Grandia (France) (Disc 2)
      @"SLES-02399" : @2, // Grandia (Germany) (Disc 1)
      @"SLES-12399" : @2, // Grandia (Germany) (Disc 2)
      @"SLPS-02124" : @2, // Grandia (Japan) (Disc 1)
      @"SLPS-02125" : @2, // Grandia (Japan) (Disc 2)
      @"SCUS-94457" : @2, // Grandia (USA) (Disc 1)
      @"SCUS-94465" : @2, // Grandia (USA) (Disc 2)
      @"SLPS-02380" : @2, // Growlanser (Japan) (Disc 1)
      @"SLPS-02381" : @2, // Growlanser (Japan) (Disc 2)
      @"SLPS-01297" : @2, // Guardian Recall - Shugojuu Shoukan (Japan) (Disc 1)
      @"SLPS-01298" : @2, // Guardian Recall - Shugojuu Shoukan (Japan) (Disc 2)
      @"SLPS-00815" : @2, // Gundam 0079 - The War for Earth (Japan) (Disc 1)
      @"SLPS-00816" : @2, // Gundam 0079 - The War for Earth (Japan) (Disc 2)
      @"SLES-02441" : @2, // GZSZ Vol. 2 (Germany) (Disc 1)
      @"SLES-12441" : @2, // GZSZ Vol. 2 (Germany) (Disc 2)
      @"SLPS-00578" : @3, // Harukaze Sentai V-Force (Japan) (Disc 1)
      @"SLPS-00579" : @3, // Harukaze Sentai V-Force (Japan) (Disc 2)
      @"SLPS-00580" : @3, // Harukaze Sentai V-Force (Japan) (Disc 3)
      @"SLES-00461" : @2, // Heart of Darkness (Europe) (Disc 1) (EDC) / (No EDC)
      @"SLES-10461" : @2, // Heart of Darkness (Europe) (Disc 2)
      @"SLES-00462" : @2, // Heart of Darkness (France) (Disc 1)
      @"SLES-10462" : @2, // Heart of Darkness (France) (Disc 2)
      @"SLES-00463" : @2, // Heart of Darkness (Germany) (Disc 1)
      @"SLES-10463" : @2, // Heart of Darkness (Germany) (Disc 2) (EDC) / (No EDC)
      @"SLES-00464" : @2, // Heart of Darkness (Italy) (Disc 1)
      @"SLES-10464" : @2, // Heart of Darkness (Italy) (Disc 2)
      @"SLES-00465" : @2, // Heart of Darkness (Spain) (Disc 1)
      @"SLES-10465" : @2, // Heart of Darkness (Spain) (Disc 2)
      @"SLUS-00696" : @2, // Heart of Darkness (USA) (Disc 1)
      @"SLUS-00741" : @2, // Heart of Darkness (USA) (Disc 2)
      @"SLPS-03340" : @4, // Helix - Fear Effect (Japan) (Disc 1)
      @"SLPS-03341" : @4, // Helix - Fear Effect (Japan) (Disc 2)
      @"SLPS-03342" : @4, // Helix - Fear Effect (Japan) (Disc 3)
      @"SLPS-03343" : @4, // Helix - Fear Effect (Japan) (Disc 4)
      @"SLPS-02641" : @2, // Hexamoon Guardians (Japan) (Disc 1)
      @"SLPS-02642" : @2, // Hexamoon Guardians (Japan) (Disc 2)
      @"SLPS-01890" : @3, // Himiko-den - Renge (Japan) (Disc 1)
      @"SLPS-01891" : @3, // Himiko-den - Renge (Japan) (Disc 2)
      @"SLPS-01892" : @3, // Himiko-den - Renge (Japan) (Disc 3)
      @"SLPS-01626" : @2, // Himitsu Sentai Metamor V Deluxe (Japan) (Disc 1)
      @"SLPS-01627" : @2, // Himitsu Sentai Metamor V Deluxe (Japan) (Disc 2)
      @"SLPS-00325" : @2, // Hive Wars, The (Japan) (Disc 1)
      @"SLPS-00326" : @2, // Hive Wars, The (Japan) (Disc 2)
      @"SLUS-00120" : @2, // Hive, The (USA) (Disc 1)
      @"SLUS-00182" : @2, // Hive, The (USA) (Disc 2)
      @"SLPS-00290" : @3, // Idol Janshi Suchie-Pai II Limited (Japan) (Disc 1)
      @"SLPS-00291" : @3, // Idol Janshi Suchie-Pai II Limited (Japan) (Disc 2) (Bonus Disc Part 1)
      @"SLPS-00292" : @3, // Idol Janshi Suchie-Pai II Limited (Japan) (Disc 3) (Bonus Disc Part 2)
      @"SCES-02149" : @2, // In Cold Blood (Europe) (Disc 1)
      @"SCES-12149" : @2, // In Cold Blood (Europe) (Disc 2)
      @"SLUS-01294" : @2, // In Cold Blood (USA) (Disc 1)
      @"SLUS-01314" : @2, // In Cold Blood (USA) (Disc 2)
      @"SLPS-00144" : @2, // J.B. Harold - Blue Chicago Blues (Japan) (Disc 1)
      @"SLPS-00145" : @2, // J.B. Harold - Blue Chicago Blues (Japan) (Disc 2)
      @"SLPS-02076" : @2, // JailBreaker (Japan) (Disc 1)
      @"SLPS-02077" : @2, // JailBreaker (Japan) (Disc 2)
      @"SLPS-00397" : @2, // Jikuu Tantei DD - Maboroshi no Lorelei (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPS-00398" : @2, // Jikuu Tantei DD - Maboroshi no Lorelei (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01533" : @2, // Jikuu Tantei DD 2 - Hangyaku no Apusararu (Japan) (Disc 1)
      @"SLPS-01534" : @2, // Jikuu Tantei DD 2 - Hangyaku no Apusararu (Japan) (Disc 2)
      @"SLPM-86342" : @2, // Jissen Pachi-Slot Hisshouhou! Single - Kamen Rider & Gallop (Japan) (Disc 1) (Kamen Rider)
      @"SLPM-86343" : @2, // Jissen Pachi-Slot Hisshouhou! Single - Kamen Rider & Gallop (Japan) (Disc 2) (Gallop)
      @"SLPS-01671" : @3, // Juggernaut - Senritsu no Tobira (Japan) (Disc 1)
      @"SLPS-01672" : @3, // Juggernaut - Senritsu no Tobira (Japan) (Disc 2)
      @"SLPS-01673" : @3, // Juggernaut - Senritsu no Tobira (Japan) (Disc 3)
      @"SLUS-00894" : @3, // Juggernaut (USA) (Disc 1)
      @"SLUS-00988" : @3, // Juggernaut (USA) (Disc 2)
      @"SLUS-00989" : @3, // Juggernaut (USA) (Disc 3)
      @"SLPS-00563" : @2, // Karyuujou (Japan) (Disc 1) (Ryuu Hangan Hen)
      @"SLPS-00564" : @2, // Karyuujou (Japan) (Disc 2) (Kou Yuukan Hen)
      @"SLPS-02570" : @2, // Kidou Senshi Gundam - Gihren no Yabou - Zeon no Keifu (Japan) (Disc 1) (Earth Federation Disc) (v1.0) / (v1.1)
      @"SLPS-02571" : @2, // Kidou Senshi Gundam - Gihren no Yabou - Zeon no Keifu (Japan) (Disc 2) (Zeon Disc) (v1.0) / (v1.1)
      @"SLPS-01142" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 1) (v1.0)
      @"SLPS-01143" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 2) (v1.0)
      @"SCPS-45160" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 1) (v1.1)
      @"SCPS-45161" : @2, // Kidou Senshi Z-Gundam (Japan) (Disc 2) (v1.1)
      @"SLPS-01340" : @2, // Kindaichi Shounen no Jikenbo 2 - Jigoku Yuuen Satsujin Jiken (Japan) (Disc 1)
      @"SLPS-01341" : @2, // Kindaichi Shounen no Jikenbo 2 - Jigoku Yuuen Satsujin Jiken (Japan) (Disc 2)
      @"SLPS-02223" : @2, // Kindaichi Shounen no Jikenbo 3 - Seiryuu Densetsu Satsujin Jiken (Japan) (Disc 1)
      @"SLPS-02224" : @2, // Kindaichi Shounen no Jikenbo 3 - Seiryuu Densetsu Satsujin Jiken (Japan) (Disc 2)
      @"SLPS-02681" : @2, // Kizuna toyuu Na no Pendant with Toybox Stories (Japan) (Disc 1)
      @"SLPS-02682" : @2, // Kizuna toyuu Na no Pendant with Toybox Stories (Japan) (Disc 2)
      @"SLES-02897" : @4, // Koudelka (Europe) (Disc 1)
      @"SLES-12897" : @4, // Koudelka (Europe) (Disc 2)
      @"SLES-22897" : @4, // Koudelka (Europe) (Disc 3)
      @"SLES-32897" : @4, // Koudelka (Europe) (Disc 4)
      @"SLES-02898" : @4, // Koudelka (France) (Disc 1)
      @"SLES-12898" : @4, // Koudelka (France) (Disc 2)
      @"SLES-22898" : @4, // Koudelka (France) (Disc 3)
      @"SLES-32898" : @4, // Koudelka (France) (Disc 4)
      @"SLES-02899" : @4, // Koudelka (Germany) (Disc 1)
      @"SLES-12899" : @4, // Koudelka (Germany) (Disc 2)
      @"SLES-22899" : @4, // Koudelka (Germany) (Disc 3)
      @"SLES-32899" : @4, // Koudelka (Germany) (Disc 4)
      @"SLES-02900" : @4, // Koudelka (Italy) (Disc 1)
      @"SLES-12900" : @4, // Koudelka (Italy) (Disc 2)
      @"SLES-22900" : @4, // Koudelka (Italy) (Disc 3)
      @"SLES-32900" : @4, // Koudelka (Italy) (Disc 4)
      @"SLPS-02460" : @4, // Koudelka (Japan) (Disc 1)
      @"SLPS-02461" : @4, // Koudelka (Japan) (Disc 2)
      @"SLPS-02462" : @4, // Koudelka (Japan) (Disc 3)
      @"SLPS-02463" : @4, // Koudelka (Japan) (Disc 4)
      @"SLES-02901" : @4, // Koudelka (Spain) (Disc 1)
      @"SLES-12901" : @4, // Koudelka (Spain) (Disc 2)
      @"SLES-22901" : @4, // Koudelka (Spain) (Disc 3)
      @"SLES-32901" : @4, // Koudelka (Spain) (Disc 4)
      @"SLUS-01051" : @4, // Koudelka (USA) (Disc 1)
      @"SLUS-01100" : @4, // Koudelka (USA) (Disc 2)
      @"SLUS-01101" : @4, // Koudelka (USA) (Disc 3)
      @"SLUS-01102" : @4, // Koudelka (USA) (Disc 4)
      @"SLPS-00669" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 1) (Byakko)
      @"SLPS-00670" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 2) (Genbu)
      @"SLPS-00671" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 3) (Suzaku)
      @"SLPS-00672" : @4, // Kowloon's Gate - Kowloon Fuusuiden (Japan) (Disc 4) (Seiryuu)
      //@"SLPS-01818" : @2, // Langrisser IV & V - Final Edition (Japan) (Disc 1) (Langrisser IV Disc)
      //@"SLPS-01819" : @2, // Langrisser IV & V - Final Edition (Japan) (Disc 2) (Langrisser V Disc)
      @"SCES-03043" : @4, // Legend of Dragoon, The (Europe) (Disc 1)
      @"SCES-13043" : @4, // Legend of Dragoon, The (Europe) (Disc 2)
      @"SCES-23043" : @4, // Legend of Dragoon, The (Europe) (Disc 3)
      @"SCES-33043" : @4, // Legend of Dragoon, The (Europe) (Disc 4)
      @"SCES-03044" : @4, // Legend of Dragoon, The (France) (Disc 1)
      @"SCES-13044" : @4, // Legend of Dragoon, The (France) (Disc 2)
      @"SCES-23044" : @4, // Legend of Dragoon, The (France) (Disc 3)
      @"SCES-33044" : @4, // Legend of Dragoon, The (France) (Disc 4)
      @"SCES-03045" : @4, // Legend of Dragoon, The (Germany) (Disc 1)
      @"SCES-13045" : @4, // Legend of Dragoon, The (Germany) (Disc 2)
      @"SCES-23045" : @4, // Legend of Dragoon, The (Germany) (Disc 3)
      @"SCES-33045" : @4, // Legend of Dragoon, The (Germany) (Disc 4)
      @"SCES-03046" : @4, // Legend of Dragoon, The (Italy) (Disc 1)
      @"SCES-13046" : @4, // Legend of Dragoon, The (Italy) (Disc 2)
      @"SCES-23046" : @4, // Legend of Dragoon, The (Italy) (Disc 3)
      @"SCES-33046" : @4, // Legend of Dragoon, The (Italy) (Disc 4)
      @"SCPS-10119" : @4, // Legend of Dragoon, The (Japan) (Disc 1)
      @"SCPS-10120" : @4, // Legend of Dragoon, The (Japan) (Disc 2)
      @"SCPS-10121" : @4, // Legend of Dragoon, The (Japan) (Disc 3)
      @"SCPS-10122" : @4, // Legend of Dragoon, The (Japan) (Disc 4)
      @"SCES-03047" : @4, // Legend of Dragoon, The (Spain) (Disc 1)
      @"SCES-13047" : @4, // Legend of Dragoon, The (Spain) (Disc 2)
      @"SCES-23047" : @4, // Legend of Dragoon, The (Spain) (Disc 3)
      @"SCES-33047" : @4, // Legend of Dragoon, The (Spain) (Disc 4)
      @"SCUS-94491" : @4, // Legend of Dragoon, The (USA) (Disc 1)
      @"SCUS-94584" : @4, // Legend of Dragoon, The (USA) (Disc 2)
      @"SCUS-94585" : @4, // Legend of Dragoon, The (USA) (Disc 3)
      @"SCUS-94586" : @4, // Legend of Dragoon, The (USA) (Disc 4)
      @"SLPS-00185" : @2, // Lifescape - Seimei 40 Okunen Haruka na Tabi (Japan) (Disc 1) (Aquasphere)
      @"SLPS-00186" : @2, // Lifescape - Seimei 40 Okunen Haruka na Tabi (Japan) (Disc 2) (Landsphere)
      @"SLPM-86269" : @2, // Little Lovers - She So Game (Japan) (Disc 1)
      @"SLPM-86270" : @2, // Little Lovers - She So Game (Japan) (Disc 2)
      @"SLPS-03012" : @2, // Little Princess +1 - Marl Oukoku no Ningyou Hime 2 (Japan) (Disc 1)
      @"SLPS-03013" : @2, // Little Princess +1 - Marl Oukoku no Ningyou Hime 2 (Japan) (Disc 2)
      @"SLES-03174" : @2, // Louvre - L'Ultime Malediction (France) (Disc 1)
      @"SLES-13174" : @2, // Louvre - L'Ultime Malediction (France) (Disc 2)
      @"SLES-03161" : @2, // Louvre - La maldicion final (Spain) (Disc 1)
      @"SLES-13161" : @2, // Louvre - La maldicion final (Spain) (Disc 2)
      @"SLES-03160" : @2, // Louvre - La Maledizione Finale (Italy) (Disc 1)
      @"SLES-13160" : @2, // Louvre - La Maledizione Finale (Italy) (Disc 2)
      @"SLES-03158" : @2, // Louvre - The Final Curse (Europe) (Disc 1)
      @"SLES-13158" : @2, // Louvre - The Final Curse (Europe) (Disc 2)
      @"SLPS-01397" : @2, // Lunar - Silver Star Story (Japan) (Disc 1)
      @"SLPS-01398" : @2, // Lunar - Silver Star Story (Japan) (Disc 2)
      @"SLUS-00628" : @2, // Lunar - Silver Star Story Complete (USA) (Disc 1)
      @"SLUS-00899" : @2, // Lunar - Silver Star Story Complete (USA) (Disc 2)
      @"SLPS-02081" : @3, // Lunar 2 - Eternal Blue (Japan) (Disc 1)
      @"SLPS-02082" : @3, // Lunar 2 - Eternal Blue (Japan) (Disc 2)
      @"SLPS-02083" : @3, // Lunar 2 - Eternal Blue (Japan) (Disc 3)
      @"SLUS-01071" : @3, // Lunar 2 - Eternal Blue Complete (USA) (Disc 1)
      @"SLUS-01239" : @3, // Lunar 2 - Eternal Blue Complete (USA) (Disc 2)
      @"SLUS-01240" : @3, // Lunar 2 - Eternal Blue Complete (USA) (Disc 3)
      @"SLPS-00535" : @3, // Lupin 3sei - Cagliostro no Shiro - Saikai (Japan) (Disc 1)
      @"SLPS-00536" : @3, // Lupin 3sei - Cagliostro no Shiro - Saikai (Japan) (Disc 2)
      @"SLPS-00537" : @3, // Lupin 3sei - Cagliostro no Shiro - Saikai (Japan) (Disc 3)
      @"SLPS-02576" : @2, // Ma-Jyan de Pon! Hanahuda de Koi! Our Graduation (Japan) (Disc 1) (Ma-Jyan de Pon! Our Graduation)
      @"SLPS-02577" : @2, // Ma-Jyan de Pon! Hanahuda de Koi! Our Graduation (Japan) (Disc 2) (Hanahuda de Koi! Our Graduation)
      @"SLPS-02705" : @2, // Maboroshi Tsukiyo - Tsukiyono Kitan (Japan) (Disc 1)
      @"SLPS-02706" : @2, // Maboroshi Tsukiyo - Tsukiyono Kitan (Japan) (Disc 2)
      //@"SLES-02964" : @2, // Magical Drop III (Europe) (En,Fr,De,Es,It,Nl) (Disc 1) (Magical Drop III)
      //@"SLES-12964" : @2, // Magical Drop III (Europe) (En,Fr,De,Es,It,Nl) (Disc 2) (Magical Drop +1)
      @"SLPS-00645" : @2, // Mahou Shoujo Pretty Samy - Part 1 - In the Earth (Japan) (Disc 1) (Episode 23)
      @"SLPS-00646" : @2, // Mahou Shoujo Pretty Samy - Part 1 - In the Earth (Japan) (Disc 2) (Episode 24)
      @"SLPS-00760" : @2, // Mahou Shoujo Pretty Samy - Part 2 - In the Julyhelm (Japan) (Disc 1) (Episode 25)
      @"SLPS-00761" : @2, // Mahou Shoujo Pretty Samy - Part 2 - In the Julyhelm (Japan) (Disc 2) (Episode 26)
      @"SLPS-01136" : @3, // Maria - Kimitachi ga Umareta Wake (Japan) (Disc 1)
      @"SLPS-01137" : @3, // Maria - Kimitachi ga Umareta Wake (Japan) (Disc 2)
      @"SLPS-01138" : @3, // Maria - Kimitachi ga Umareta Wake (Japan) (Disc 3)
      @"SLPS-02240" : @3, // Maria 2 - Jutai Kokuchi no Nazo (Japan) (Disc 1)
      @"SLPS-02241" : @3, // Maria 2 - Jutai Kokuchi no Nazo (Japan) (Disc 2)
      @"SLPS-02242" : @3, // Maria 2 - Jutai Kokuchi no Nazo (Japan) (Disc 3)
      @"SLPM-87148" : @2, // Martialbeat 2 (Japan) (Disc 1) (Disc-B)
      @"SLPM-87149" : @2, // Martialbeat 2 (Japan) (Disc 2) (Disc-F)
      @"SLPM-87146" : @2, // Martialbeat 2 (Japan) (Disc 1) (Disc-B) (Controller Doukon Set)
      @"SLPM-87147" : @2, // Martialbeat 2 (Japan) (Disc 2) (Disc-F) (Controller Doukon Set)
      @"SLPS-03220" : @2, // Matsumoto Reiji 999 - Story of Galaxy Express 999 (Japan) (Disc 1)
      @"SLPS-03221" : @2, // Matsumoto Reiji 999 - Story of Galaxy Express 999 (Japan) (Disc 2)
      @"SLPS-01147" : @2, // Meltylancer - Re-inforce (Japan) (Disc 1)
      @"SLPS-01148" : @2, // Meltylancer - Re-inforce (Japan) (Disc 2)
      @"SLPM-86231" : @2, // Meltylancer - The 3rd Planet (Japan) (Disc 1)
      @"SLPM-86232" : @2, // Meltylancer - The 3rd Planet (Japan) (Disc 2)
      @"SLPS-03292" : @2, // Memories Off 2nd (Japan) (Disc 1)
      @"SLPS-03293" : @2, // Memories Off 2nd (Japan) (Disc 2)
      @"SLPS-03289" : @3, // Memories Off 2nd (Japan) (Disc 1) (Shokai Genteiban)
      @"SLPS-03290" : @3, // Memories Off 2nd (Japan) (Disc 2) (Shokai Genteiban)
      @"SLPS-03291" : @3, // Memories Off 2nd (Japan) (Disc 3) (Making Disc) (Shokai Genteiban)
      @"SLPM-87108" : @2, // Mermaid no Kisetsu - Curtain Call (Japan) (Disc 1)
      @"SLPM-87109" : @2, // Mermaid no Kisetsu - Curtain Call (Japan) (Disc 2)
      @"SLPM-86934" : @3, // Mermaid no Kisetsu (Japan) (Disc 1)
      @"SLPM-86935" : @3, // Mermaid no Kisetsu (Japan) (Disc 2)
      @"SLPM-86936" : @3, // Mermaid no Kisetsu (Japan) (Disc 3)
      @"SLPS-00680" : @2, // Meta-Ph-List Gamma X 2297 (Japan) (Disc 1)
      @"SLPS-00681" : @2, // Meta-Ph-List Gamma X 2297 (Japan) (Disc 2)
      @"SLPS-00680" : @2, // Meta-Ph-List Mu.X.2297 (Japan) (Disc 1)
      @"SLPS-00681" : @2, // Meta-Ph-List Mu.X.2297 (Japan) (Disc 2)
      @"SLPS-00867" : @2, // Metal Angel 3 (Japan) (Disc 1)
      @"SLPS-00868" : @2, // Metal Angel 3 (Japan) (Disc 2)
      @"SLPM-86247" : @2, // Metal Gear Solid - Integral (Japan) (En,Ja) (Disc 1)
      @"SLPM-86248" : @2, // Metal Gear Solid - Integral (Japan) (En,Ja) (Disc 2)
      //@"SLPM-86249" : @3, // Metal Gear Solid - Integral (Japan) (Disc 3) (VR-Disc)
      @"SCPS-45317" : @2, // Metal Gear Solid (Asia) (Disc 1)
      @"SCPS-45318" : @2, // Metal Gear Solid (Asia) (Disc 2)
      @"SLES-01370" : @2, // Metal Gear Solid (Europe) (Disc 1)
      @"SLES-11370" : @2, // Metal Gear Solid (Europe) (Disc 2)
      @"SLES-01506" : @2, // Metal Gear Solid (France) (Disc 1)
      @"SLES-11506" : @2, // Metal Gear Solid (France) (Disc 2)
      @"SLES-01507" : @2, // Metal Gear Solid (Germany) (Disc 1)
      @"SLES-11507" : @2, // Metal Gear Solid (Germany) (Disc 2)
      @"SLES-01508" : @2, // Metal Gear Solid (Italy) (Disc 1)
      @"SLES-11508" : @2, // Metal Gear Solid (Italy) (Disc 2)
      @"SLPM-86111" : @2, // Metal Gear Solid (Japan) (Disc 1) (Ichi)
      @"SLPM-86112" : @2, // Metal Gear Solid (Japan) (Disc 2) (Ni)
      @"SLES-01734" : @2, // Metal Gear Solid (Spain) (Disc 1) (v1.1)
      @"SLES-11734" : @2, // Metal Gear Solid (Spain) (Disc 2) (v1.1)
      @"SLUS-00594" : @2, // Metal Gear Solid (USA) (Disc 1) (v1.0) / (v1.1)
      @"SLUS-00776" : @2, // Metal Gear Solid (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01611" : @2, // Mikagura Shoujo Tanteidan (Japan) (Disc 1)
      @"SLPS-01612" : @2, // Mikagura Shoujo Tanteidan (Japan) (Disc 2)
      @"SLPS-01609" : @2, // Million Classic (Japan) (Disc 1) (Honpen Game Senyou)
      @"SLPS-01610" : @2, // Million Classic (Japan) (Disc 2) (Taisen Game Senyou)
      @"SLPS-00951" : @2, // Minakata Hakudou Toujou (Japan) (Disc 1)
      @"SLPS-00952" : @2, // Minakata Hakudou Toujou (Japan) (Disc 2)
      @"SLPS-01276" : @2, // Misa no Mahou Monogatari (Japan) (Disc 1)
      @"SLPS-01277" : @2, // Misa no Mahou Monogatari (Japan) (Disc 2)
      @"SLES-03813" : @2, // Monte Carlo Games Compendium (Europe) (Disc 1)
      @"SLES-13813" : @2, // Monte Carlo Games Compendium (Europe) (Disc 2)
      @"SLPS-01001" : @2, // Moonlight Syndrome (Japan) (Disc 1)
      @"SLPS-01002" : @2, // Moonlight Syndrome (Japan) (Disc 2)
      @"SLPM-86130" : @2, // Moritaka Chisato - Safari Tokyo (Japan) (Disc 1)
      @"SLPM-86131" : @2, // Moritaka Chisato - Safari Tokyo (Japan) (Disc 2)
      @"SCPS-10018" : @2, // Motor Toon Grand Prix 2 (Japan) (Disc 1)
      @"SCPS-10019" : @2, // Motor Toon Grand Prix 2 (Japan) (Disc 2) (Taisen Senyou Disc)
      @"SLPS-01988" : @2, // Murakoshi Seikai no Bakuchou SeaBass Fishing (Japan) (Disc 1)
      @"SLPS-01989" : @2, // Murakoshi Seikai no Bakuchou SeaBass Fishing (Japan) (Disc 2)
      @"SLPS-00996" : @2, // My Dream - On Air ga Matenakute (Japan) (Disc 1)
      @"SLPS-00997" : @2, // My Dream - On Air ga Matenakute (Japan) (Disc 2)
      @"SLPS-01562" : @2, // Mystic Mind - Yureru Omoi (Japan) (Disc 1)
      @"SLPS-01563" : @2, // Mystic Mind - Yureru Omoi (Japan) (Disc 2)
      @"SLPM-86179" : @3, // Nanatsu no Hikan (Japan) (Disc 1)
      @"SLPM-86180" : @3, // Nanatsu no Hikan (Japan) (Disc 2)
      @"SLPM-86181" : @3, // Nanatsu no Hikan (Japan) (Disc 3)
      @"SLES-03495" : @2, // Necronomicon - Das Mysterium der Daemmerung (Germany) (Disc 1)
      @"SLES-13495" : @2, // Necronomicon - Das Mysterium der Daemmerung (Germany) (Disc 2)
      @"SLES-03497" : @2, // Necronomicon - El Alba de las Tinieblas (Spain) (Disc 1)
      @"SLES-13497" : @2, // Necronomicon - El Alba de las Tinieblas (Spain) (Disc 2)
      @"SLES-03496" : @2, // Necronomicon - Ispirato Alle Opere Di (Italy) (Disc 1)
      @"SLES-13496" : @2, // Necronomicon - Ispirato Alle Opere Di (Italy) (Disc 2)
      @"SLES-03494" : @2, // Necronomicon - L'Aube des Tenebres (France) (Disc 1)
      @"SLES-13494" : @2, // Necronomicon - L'Aube des Tenebres (France) (Disc 2)
      @"SLES-03498" : @2, // Necronomicon - O Despertar das Trevas (Portugal) (Disc 1)
      @"SLES-13498" : @2, // Necronomicon - O Despertar das Trevas (Portugal) (Disc 2)
      @"SLES-03493" : @2, // Necronomicon - The Dawning of Darkness (Europe) (Disc 1)
      @"SLES-13493" : @2, // Necronomicon - The Dawning of Darkness (Europe) (Disc 2)
      @"SLPS-01543" : @3, // Neko Zamurai (Japan) (Disc 1)
      @"SLPS-01544" : @3, // Neko Zamurai (Japan) (Disc 2)
      @"SLPS-01545" : @3, // Neko Zamurai (Japan) (Disc 3)
      //@"SLPS-00823" : @2, // Neorude (Japan) (Disc 1) (Game Disc)
      //@"SLPS-00824" : @2, // Neorude (Japan) (Disc 2) (Special Disc)
      @"SLPS-00913" : @2, // Nessa no Hoshi (Japan) (Disc 1)
      @"SLPS-00914" : @2, // Nessa no Hoshi (Japan) (Disc 2)
      @"SLPS-01045" : @3, // Nightmare Project - Yakata (Japan) (Disc 1)
      @"SLPS-01046" : @3, // Nightmare Project - Yakata (Japan) (Disc 2)
      @"SLPS-01047" : @3, // Nightmare Project - Yakata (Japan) (Disc 3)
      @"SLPS-01193" : @3, // NOeL - La Neige (Japan) (Disc 1)
      @"SLPS-01194" : @3, // NOeL - La Neige (Japan) (Disc 2)
      @"SLPS-01195" : @3, // NOeL - La Neige (Japan) (Disc 3)
      @"SLPS-01190" : @3, // NOeL - La Neige (Japan) (Disc 1) (Special Edition)
      @"SLPS-01191" : @3, // NOeL - La Neige (Japan) (Disc 2) (Special Edition)
      @"SLPS-01192" : @3, // NOeL - La Neige (Japan) (Disc 3) (Special Edition)
      @"SLPS-00304" : @2, // NOeL - Not Digital (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPS-00305" : @2, // NOeL - Not Digital (Japan) (Disc 2)
      @"SLPS-01895" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 1)
      @"SLPS-01896" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 2)
      @"SLPS-01897" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 3)
      @"SLPM-86609" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 1) (Major Wave Series)
      @"SLPM-86610" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 2) (Major Wave Series)
      @"SLPM-86611" : @3, // NOeL 3 - Mission on the Line (Japan) (Disc 3) (Major Wave Series)
      @"SCES-00011" : @2, // Novastorm (Europe) (Disc 1)
      @"SCES-10011" : @2, // Novastorm (Europe) (Disc 2)
      @"SLPS-00314" : @2, // Novastorm (Japan) (Disc 1)
      @"SLPS-00315" : @2, // Novastorm (Japan) (Disc 2)
      @"SCUS-94404" : @2, // Novastorm (USA) (Disc 1)
      @"SCUS-94407" : @2, // Novastorm (USA) (Disc 2)
      @"SLES-01480" : @2, // Oddworld - Abe's Exoddus (Europe) (Disc 1)
      @"SLES-11480" : @2, // Oddworld - Abe's Exoddus (Europe) (Disc 2)
      @"SLES-01503" : @2, // Oddworld - Abe's Exoddus (Germany) (Disc 1)
      @"SLES-11503" : @2, // Oddworld - Abe's Exoddus (Germany) (Disc 2)
      @"SLES-01504" : @2, // Oddworld - Abe's Exoddus (Italy) (Disc 1)
      @"SLES-11504" : @2, // Oddworld - Abe's Exoddus (Italy) (Disc 2)
      @"SLES-01505" : @2, // Oddworld - Abe's Exoddus (Spain) (Disc 1)
      @"SLES-11505" : @2, // Oddworld - Abe's Exoddus (Spain) (Disc 2)
      @"SLUS-00710" : @2, // Oddworld - Abe's Exoddus (USA) (Disc 1)
      @"SLUS-00731" : @2, // Oddworld - Abe's Exoddus (USA) (Disc 2)
      @"SLES-01502" : @2, // Oddworld - L'Exode d'Abe (France) (Disc 1)
      @"SLES-11502" : @2, // Oddworld - L'Exode d'Abe (France) (Disc 2)
      @"SLPS-01495" : @2, // Ojyousama Express (Japan) (Disc 1)
      @"SLPS-01496" : @2, // Ojyousama Express (Japan) (Disc 2)
      @"SLES-01879" : @2, // OverBlood 2 (Europe) (Disc 1) (v1.0) / (v1.1)
      @"SLES-11879" : @2, // OverBlood 2 (Europe) (Disc 2) (v1.0) / (v1.1)
      @"SLES-02187" : @2, // OverBlood 2 (Germany) (Disc 1)
      @"SLES-12187" : @2, // OverBlood 2 (Germany) (Disc 2)
      @"SLES-01880" : @2, // OverBlood 2 (Italy) (Disc 1)
      @"SLES-11880" : @2, // OverBlood 2 (Italy) (Disc 2)
      @"SLPS-01261" : @2, // OverBlood 2 (Japan) (Disc 1)
      @"SLPS-01262" : @2, // OverBlood 2 (Japan) (Disc 2)
      @"SLPS-01230" : @2, // Parasite Eve (Japan) (Disc 1)
      @"SLPS-01231" : @2, // Parasite Eve (Japan) (Disc 2)
      @"SLUS-00662" : @2, // Parasite Eve (USA) (Disc 1)
      @"SLUS-00668" : @2, // Parasite Eve (USA) (Disc 2)
      @"SLES-02558" : @2, // Parasite Eve II (Europe) (Disc 1)
      @"SLES-12558" : @2, // Parasite Eve II (Europe) (Disc 2)
      @"SLES-02559" : @2, // Parasite Eve II (France) (Disc 1)
      @"SLES-12559" : @2, // Parasite Eve II (France) (Disc 2)
      @"SLES-02560" : @2, // Parasite Eve II (Germany) (Disc 1)
      @"SLES-12560" : @2, // Parasite Eve II (Germany) (Disc 2)
      @"SLES-02562" : @2, // Parasite Eve II (Italy) (Disc 1)
      @"SLES-12562" : @2, // Parasite Eve II (Italy) (Disc 2)
      @"SLPS-02480" : @2, // Parasite Eve II (Japan) (Disc 1)
      @"SLPS-02481" : @2, // Parasite Eve II (Japan) (Disc 2)
      @"SLES-02561" : @2, // Parasite Eve II (Spain) (Disc 1)
      @"SLES-12561" : @2, // Parasite Eve II (Spain) (Disc 2)
      @"SLUS-01042" : @2, // Parasite Eve II (USA) (Disc 1)
      @"SLUS-01055" : @2, // Parasite Eve II (USA) (Disc 2)
      @"SLPM-86048" : @2, // Policenauts (Japan) (Disc 1)
      @"SLPM-86049" : @2, // Policenauts (Japan) (Disc 2)
      @"SCPS-10112" : @3, // PoPoLoCrois Monogatari II (Japan) (Disc 1)
      @"SCPS-10113" : @3, // PoPoLoCrois Monogatari II (Japan) (Disc 2)
      @"SCPS-10114" : @3, // PoPoLoCrois Monogatari II (Japan) (Disc 3)
      @"SLES-00070" : @3, // Psychic Detective (Europe) (Disc 1)
      @"SLES-10070" : @3, // Psychic Detective (Europe) (Disc 2)
      @"SLES-20070" : @3, // Psychic Detective (Europe) (Disc 3)
      @"SLUS-00165" : @3, // Psychic Detective (USA) (Disc 1)
      @"SLUS-00166" : @3, // Psychic Detective (USA) (Disc 2)
      @"SLUS-00167" : @3, // Psychic Detective (USA) (Disc 3)
      //@"SLPS-01018" : @2, // Psychic Force - Puzzle Taisen (Japan) (Disc 1) (Game Disc)
      //@"SLPS-01019" : @2, // Psychic Force - Puzzle Taisen (Japan) (Disc 2) (Premium CD-ROM)
      @"SCPS-18004" : @2, // Quest for Fame - Be a Virtual Rock Legend (Japan) (Disc 1)
      @"SCPS-18005" : @2, // Quest for Fame - Be a Virtual Rock Legend (Japan) (Disc 2)
      @"SLES-03752" : @2, // Quiz Show (Italy) (Disc 1)
      @"SLES-13752" : @2, // Quiz Show (Italy) (Disc 2)
      @"SLES-00519" : @2, // Raven Project, The (Europe) (En,Fr,De) (Disc 1)
      @"SLES-10519" : @2, // Raven Project, The (Europe) (En,Fr,De) (Disc 2)
      @"SLES-00519" : @2, // Raven Project, The (Germany) (En,Fr,De) (Disc 1)
      @"SLES-10519" : @2, // Raven Project, The (Germany) (En,Fr,De) (Disc 2)
      @"SLPS-01840" : @2, // Refrain Love 2 (Japan) (Disc 1)
      @"SLPS-01841" : @2, // Refrain Love 2 (Japan) (Disc 2)
      @"SLPS-01588" : @2, // Renai Kouza - Real Age (Japan) (Disc 1)
      @"SLPS-01589" : @2, // Renai Kouza - Real Age (Japan) (Disc 2)
      @"SLUS-00748" : @2, // Resident Evil 2 - Dual Shock Ver. (USA) (Disc 1) (Leon)
      @"SLUS-00756" : @2, // Resident Evil 2 - Dual Shock Ver. (USA) (Disc 2) (Claire)
      @"SLES-00972" : @2, // Resident Evil 2 (Europe) (Disc 1)
      @"SLES-10972" : @2, // Resident Evil 2 (Europe) (Disc 2)
      @"SLES-00973" : @2, // Resident Evil 2 (France) (Disc 1)
      @"SLES-10973" : @2, // Resident Evil 2 (France) (Disc 2)
      @"SLES-00974" : @2, // Resident Evil 2 (Germany) (Disc 1)
      @"SLES-10974" : @2, // Resident Evil 2 (Germany) (Disc 2)
      @"SLES-00975" : @2, // Resident Evil 2 (Italy) (Disc 1)
      @"SLES-10975" : @2, // Resident Evil 2 (Italy) (Disc 2)
      @"SLES-00976" : @2, // Resident Evil 2 (Spain) (Disc 1)
      @"SLES-10976" : @2, // Resident Evil 2 (Spain) (Disc 2)
      @"SLUS-00421" : @2, // Resident Evil 2 (USA) (Disc 1)
      @"SLUS-00592" : @2, // Resident Evil 2 (USA) (Disc 2)
      @"SLPS-00192" : @2, // Return to Zork (Japan) (Disc 1)
      @"SLPS-00193" : @2, // Return to Zork (Japan) (Disc 2)
      @"SLPS-01643" : @2, // Ridegear Guybrave II (Japan) (Disc 1)
      @"SLPS-01644" : @2, // Ridegear Guybrave II (Japan) (Disc 2)
      //@"SLES-01436" : @2, // Rival Schools - United by Fate (Europe) (Disc 1) (Evolution Disc)
      //@"SLES-11436" : @2, // Rival Schools - United by Fate (Europe) (Disc 2) (Arcade Disc)
      //@"SLUS-00681" : @2, // Rival Schools - United by Fate (USA) (Disc 1) (Arcade Disc)
      //@"SLUS-00771" : @2, // Rival Schools - United by Fate (USA) (Disc 2) (Evolution Disc)
      @"SLES-00963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 1)
      @"SLES-10963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 2)
      @"SLES-20963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 3)
      @"SLES-30963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 4)
      @"SLES-40963" : @5, // Riven - The Sequel to Myst (Europe) (Disc 5)
      @"SLES-01099" : @5, // Riven - The Sequel to Myst (France) (Disc 1)
      @"SLES-11099" : @5, // Riven - The Sequel to Myst (France) (Disc 2)
      @"SLES-21099" : @5, // Riven - The Sequel to Myst (France) (Disc 3)
      @"SLES-31099" : @5, // Riven - The Sequel to Myst (France) (Disc 4)
      @"SLES-41099" : @5, // Riven - The Sequel to Myst (France) (Disc 5)
      @"SLES-01100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 1)
      @"SLES-11100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 2)
      @"SLES-21100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 3)
      @"SLES-31100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 4)
      @"SLES-41100" : @5, // Riven - The Sequel to Myst (Germany) (Disc 5)
      @"SLPS-01180" : @5, // Riven - The Sequel to Myst (Japan) (Disc 1)
      @"SLPS-01181" : @5, // Riven - The Sequel to Myst (Japan) (Disc 2)
      @"SLPS-01182" : @5, // Riven - The Sequel to Myst (Japan) (Disc 3)
      @"SLPS-01183" : @5, // Riven - The Sequel to Myst (Japan) (Disc 4)
      @"SLPS-01184" : @5, // Riven - The Sequel to Myst (Japan) (Disc 5)
      @"SLUS-00535" : @5, // Riven - The Sequel to Myst (USA) (Disc 1)
      @"SLUS-00563" : @5, // Riven - The Sequel to Myst (USA) (Disc 2)
      @"SLUS-00564" : @5, // Riven - The Sequel to Myst (USA) (Disc 3)
      @"SLUS-00565" : @5, // Riven - The Sequel to Myst (USA) (Disc 4)
      @"SLUS-00580" : @5, // Riven - The Sequel to Myst (USA) (Disc 5)
      @"SLPS-01087" : @2, // RMJ - The Mystery Hospital (Japan) (Disc 1) (What's Going On)
      @"SLPS-01088" : @2, // RMJ - The Mystery Hospital (Japan) (Disc 2) (Fears Behind)
      @"SLPS-02861" : @2, // RPG Tkool 4 (Japan) (Disc 1)
      @"SLPS-02862" : @2, // RPG Tkool 4 (Japan) (Disc 2) (Character Tkool)
      @"SLPS-02761" : @3, // Saraba Uchuu Senkan Yamato - Ai no Senshi-tachi (Japan) (Disc 1)
      @"SLPS-02762" : @3, // Saraba Uchuu Senkan Yamato - Ai no Senshi-tachi (Japan) (Disc 2)
      @"SLPS-02763" : @3, // Saraba Uchuu Senkan Yamato - Ai no Senshi-tachi (Japan) (Disc 3)
      @"SLPS-02200" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 1) (v1.0)
      @"SLPS-02201" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 2) (v1.0)
      @"SLPS-03206" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 1) (v1.1)
      @"SLPS-03207" : @2, // SD Gundam - GGeneration-0 (Japan) (Disc 2) (v1.1)
      @"SLPS-02912" : @3, // SD Gundam - GGeneration-F (Japan) (Disc 1)
      @"SLPS-02913" : @3, // SD Gundam - GGeneration-F (Japan) (Disc 2)
      @"SLPS-02914" : @3, // SD Gundam - GGeneration-F (Japan) (Disc 3)
      @"SLPS-01603" : @2, // Serial Experiments Lain (Japan) (Disc 1)
      @"SLPS-01604" : @2, // Serial Experiments Lain (Japan) (Disc 2)
      @"SCES-02099" : @2, // Shadow Madness (Europe) (Disc 1)
      @"SCES-12099" : @2, // Shadow Madness (Europe) (Disc 2)
      @"SCES-02100" : @2, // Shadow Madness (France) (Disc 1)
      @"SCES-12100" : @2, // Shadow Madness (France) (Disc 2)
      @"SCES-02101" : @2, // Shadow Madness (Germany) (Disc 1)
      @"SCES-12101" : @2, // Shadow Madness (Germany) (Disc 2)
      @"SCES-02102" : @2, // Shadow Madness (Italy) (Disc 1)
      @"SCES-12102" : @2, // Shadow Madness (Italy) (Disc 2)
      @"SCES-02103" : @2, // Shadow Madness (Spain) (Disc 1)
      @"SCES-12103" : @2, // Shadow Madness (Spain) (Disc 2)
      @"SLUS-00468" : @2, // Shadow Madness (USA) (Disc 1)
      @"SLUS-00718" : @2, // Shadow Madness (USA) (Disc 2)
      @"SLPS-01377" : @2, // Shin Seiki Evangelion - Koutetsu no Girlfriend (Japan) (Disc 1)
      @"SLPS-01378" : @2, // Shin Seiki Evangelion - Koutetsu no Girlfriend (Japan) (Disc 2)
      //@"SLPS-01240" : @2, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 1) (Evolution Disc)
      //@"SLPS-01241" : @2, // Shiritsu Justice Gakuen - Legion of Heroes (Japan) (Disc 2) (Arcade Disc)
      //@"SLES-00071" : @2, // Shockwave Assault (Europe) (Disc 1) (Shockwave - Invasion Earth)
      //@"SLES-10071" : @2, // Shockwave Assault (Europe) (Disc 2) (Shockwave - Operation Jumpgate)
      //@"SLUS-00028" : @2, // Shockwave Assault (USA) (Disc 1) (Shockwave - Invasion Earth)
      //@"SLUS-00137" : @2, // Shockwave Assault (USA) (Disc 2) (Shockwave - Operation Jumpgate)
      @"SLPS-02401" : @2, // Shuukan Gallop - Blood Master (Japan) (Disc 1)
      @"SLPS-02402" : @2, // Shuukan Gallop - Blood Master (Japan) (Disc 2)
      @"SLPS-03154" : @2, // Sister Princess (Japan) (Disc 1) (v1.0)
      @"SLPS-03155" : @2, // Sister Princess (Japan) (Disc 2) (v1.0)
      @"SLPS-03156" : @2, // Sister Princess (Japan) (Disc 1) (v1.1)
      @"SLPS-03157" : @2, // Sister Princess (Japan) (Disc 2) (v1.1)
      @"SLPS-03521" : @2, // Sister Princess 2 (Japan) (Disc 1) (v1.0)
      @"SLPS-03522" : @2, // Sister Princess 2 (Japan) (Disc 2) (v1.0)
      @"SLPS-03523" : @2, // Sister Princess 2 (Japan) (Disc 1) (v1.1)
      @"SLPS-03524" : @2, // Sister Princess 2 (Japan) (Disc 2) (v1.1)
      @"SLPS-03556" : @2, // Sister Princess 2 - Premium Fan Disc (Japan) (Disc A)
      @"SLPS-03557" : @2, // Sister Princess 2 - Premium Fan Disc (Japan) (Disc B)
      @"SLPS-01843" : @2, // Sonata (Japan) (Disc 1)
      @"SLPS-01844" : @2, // Sonata (Japan) (Disc 2)
      @"SLPS-01444" : @2, // Sotsugyou M - Seito Kaichou no Karei naru Inbou (Japan) (Disc 1)
      @"SLPS-01445" : @2, // Sotsugyou M - Seito Kaichou no Karei naru Inbou (Japan) (Disc 2)
      @"SLPS-01722" : @2, // Sougaku Toshi - Osaka (Japan) (Disc 1)
      @"SLPS-01723" : @2, // Sougaku Toshi - Osaka (Japan) (Disc 2)
      @"SLPS-01291" : @3, // Soukaigi (Japan) (Disc 1)
      @"SLPS-01292" : @3, // Soukaigi (Japan) (Disc 2)
      @"SLPS-01293" : @3, // Soukaigi (Japan) (Disc 3)
      @"SLPS-02313" : @2, // Soukou Kihei Votoms - Koutetsu no Gunzei (Japan) (Disc 1)
      @"SLPS-02314" : @2, // Soukou Kihei Votoms - Koutetsu no Gunzei (Japan) (Disc 2)
      @"SLPS-01041" : @2, // Soukuu no Tsubasa - Gotha World (Japan) (Disc 1)
      @"SLPS-01042" : @2, // Soukuu no Tsubasa - Gotha World (Japan) (Disc 2)
      @"SLPS-01845" : @2, // Sound Novel Evolution 3 - Machi - Unmei no Kousaten (Japan) (Disc 1)
      @"SLPS-01846" : @2, // Sound Novel Evolution 3 - Machi - Unmei no Kousaten (Japan) (Disc 2)
      @"SLPM-86408" : @3, // Southern All Stars - Space MOSA Space Museum of Southern Art (Japan) (Disc 1) (Museum)
      @"SLPM-86409" : @3, // Southern All Stars - Space MOSA Space Museum of Southern Art (Japan) (Disc 2) (Library)
      @"SLPM-86410" : @3, // Southern All Stars - Space MOSA Space Museum of Southern Art (Japan) (Disc 3) (Theater)
      @"SCES-02159" : @2, // Star Ocean - The Second Story (Europe) (Disc 1)
      @"SCES-12159" : @2, // Star Ocean - The Second Story (Europe) (Disc 2)
      @"SCES-02160" : @2, // Star Ocean - The Second Story (France) (Disc 1)
      @"SCES-12160" : @2, // Star Ocean - The Second Story (France) (Disc 2)
      @"SCES-02161" : @2, // Star Ocean - The Second Story (Germany) (Disc 1)
      @"SCES-12161" : @2, // Star Ocean - The Second Story (Germany) (Disc 2)
      @"SLPM-86105" : @2, // Star Ocean - The Second Story (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPM-86106" : @2, // Star Ocean - The Second Story (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCUS-94421" : @2, // Star Ocean - The Second Story (USA) (Disc 1)
      @"SCUS-94422" : @2, // Star Ocean - The Second Story (USA) (Disc 2)
      @"SLES-00654" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Europe) (Disc 1)
      @"SLES-10654" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Europe) (Disc 2)
      @"SLES-00656" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (France) (Disc 1)
      @"SLES-10656" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (France) (Disc 2)
      @"SLES-00584" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Germany) (Disc 1)
      @"SLES-10584" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Germany) (Disc 2)
      @"SLES-00643" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Italy) (Disc 1)
      @"SLES-10643" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Italy) (Disc 2)
      @"SLPS-00638" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Japan) (Disc 1)
      @"SLPS-00639" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Japan) (Disc 2)
      @"SLES-00644" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Spain) (Disc 1)
      @"SLES-10644" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (Spain) (Disc 2)
      @"SLUS-00381" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (USA) (Disc 1)
      @"SLUS-00386" : @2, // Star Wars - Rebel Assault II - The Hidden Empire (USA) (Disc 2)
      //@"SLES-00998" : @2, // Street Fighter Collection (Europe) (Disc 1)
      //@"SLES-10998" : @2, // Street Fighter Collection (Europe) (Disc 2)
      //@"SLPS-00800" : @2, // Street Fighter Collection (Japan) (Disc 1)
      //@"SLPS-00801" : @2, // Street Fighter Collection (Japan) (Disc 2)
      //@"SLUS-00423" : @2, // Street Fighter Collection (USA) (Disc 1) (v1.0) / (v1.1)
      //@"SLUS-00584" : @2, // Street Fighter Collection (USA) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-00080" : @2, // Street Fighter II Movie (Japan) (Disc 1)
      @"SLPS-00081" : @2, // Street Fighter II Movie (Japan) (Disc 2)
      //@"SLPS-02620" : @2, // Strider Hiryuu 1 & 2 (Japan) (Disc 1) (Strider Hiryuu)
      //@"SLPS-02621" : @2, // Strider Hiryuu 1 & 2 (Japan) (Disc 2) (Strider Hiryuu 2)
      @"SLPS-01264" : @2, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 1)
      @"SLPS-01265" : @2, // Suchie-Pai Adventure - Doki Doki Nightmare (Japan) (Disc 2)
      @"SLPS-03237" : @2, // Summon Night 2 (Japan) (Disc 1)
      @"SLPS-03238" : @2, // Summon Night 2 (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPS-01051" : @3, // Super Adventure Rockman (Japan) (Disc 1) (Episode 1 Tsuki no Shinden)
      @"SLPS-01052" : @3, // Super Adventure Rockman (Japan) (Disc 2) (Episode 2 Shitou! Wily Numbers)
      @"SLPS-01053" : @3, // Super Adventure Rockman (Japan) (Disc 3) (Episode 3 Saigo no Tatakai!!)
      @"SLPS-02070" : @2, // Super Robot Taisen - Complete Box (Japan) (Disc 1) (Super Robot Wars Complete Box)
      @"SLPS-02071" : @2, // Super Robot Taisen - Complete Box (Japan) (Disc 2) (History of Super Robot Wars)
      @"SCES-02289" : @2, // Syphon Filter 2 - Conspiracion Mortal (Spain) (Disc 1)
      @"SCES-12289" : @2, // Syphon Filter 2 - Conspiracion Mortal (Spain) (Disc 2)
      @"SCES-02285" : @2, // Syphon Filter 2 (Europe) (Disc 1) (v1.0) / (v1.1)
      @"SCES-12285" : @2, // Syphon Filter 2 (Europe) (Disc 2) (v1.0) / (v1.1)
      @"SCES-02286" : @2, // Syphon Filter 2 (France) (Disc 1)
      @"SCES-12286" : @2, // Syphon Filter 2 (France) (Disc 2)
      @"SCES-02287" : @2, // Syphon Filter 2 (Germany) (Disc 1) (EDC) / (No EDC)
      @"SCES-12287" : @2, // Syphon Filter 2 (Germany) (Disc 2)
      @"SCES-02288" : @2, // Syphon Filter 2 (Italy) (Disc 1)
      @"SCES-12288" : @2, // Syphon Filter 2 (Italy) (Disc 2)
      @"SCUS-94451" : @2, // Syphon Filter 2 (USA) (Disc 1)
      @"SCUS-94492" : @2, // Syphon Filter 2 (USA) (Disc 2)
      @"SLPM-86782" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 1)
      @"SLPM-86783" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 2)
      @"SLPM-86780" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 1) (Shokai Genteiban)
      @"SLPM-86781" : @2, // Taiho Shichauzo - You're Under Arrest (Japan) (Disc 2) (Shokai Genteiban)
      @"SLUS-01355" : @3, // Tales of Destiny II (USA) (Disc 1)
      @"SLUS-01367" : @3, // Tales of Destiny II (USA) (Disc 2)
      @"SLUS-01368" : @3, // Tales of Destiny II (USA) (Disc 3)
      @"SLPS-03050" : @3, // Tales of Eternia (Japan) (Disc 1)
      @"SLPS-03051" : @3, // Tales of Eternia (Japan) (Disc 2)
      @"SLPS-03052" : @3, // Tales of Eternia (Japan) (Disc 3)
      @"SLPS-00451" : @2, // Tenchi Muyou! Toukou Muyou (Japan) (Disc 1)
      @"SLPS-00452" : @2, // Tenchi Muyou! Toukou Muyou (Japan) (Disc 2)
      @"SLPS-01780" : @2, // Thousand Arms (Japan) (Disc 1)
      @"SLUS-00845" : @2, // Thousand Arms (Japan) (Disc 2)
      @"SLPS-01781" : @2, // Thousand Arms (USA) (Disc 1)
      @"SLUS-00858" : @2, // Thousand Arms (USA) (Disc 2)
      //@"SLPS-00094" : @2, // Thunder Storm & Road Blaster (Japan) (Disc 1) (Thunder Storm)
      //@"SLPS-00095" : @2, // Thunder Storm & Road Blaster (Japan) (Disc 2) (Road Blaster)
      @"SLPS-01919" : @2, // To Heart (Japan) (Disc 1)
      @"SLPS-01920" : @2, // To Heart (Japan) (Disc 2)
      @"SLPM-86355" : @5, // Tokimeki Memorial 2 (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SLPM-86356" : @5, // Tokimeki Memorial 2 (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SLPM-86357" : @5, // Tokimeki Memorial 2 (Japan) (Disc 3) (v1.0) / (v1.1)
      @"SLPM-86358" : @5, // Tokimeki Memorial 2 (Japan) (Disc 4) (v1.0) / (v1.1)
      @"SLPM-86359" : @5, // Tokimeki Memorial 2 (Japan) (Disc 5) (v1.0) / (v1.1)
      @"SLPM-86549" : @2, // Tokimeki Memorial 2 Substories - Dancing Summer Vacation (Japan) (Disc 1)
      @"SLPM-86550" : @2, // Tokimeki Memorial 2 Substories - Dancing Summer Vacation (Japan) (Disc 2)
      @"SLPM-86775" : @2, // Tokimeki Memorial 2 Substories - Leaping School Festival (Japan) (Disc 1)
      @"SLPM-86776" : @2, // Tokimeki Memorial 2 Substories - Leaping School Festival (Japan) (Disc 2)
      @"SLPM-86881" : @2, // Tokimeki Memorial 2 Substories Vol. 3 - Memories Ringing On (Japan) (Disc 1)
      @"SLPM-86882" : @2, // Tokimeki Memorial 2 Substories Vol. 3 - Memories Ringing On (Japan) (Disc 2)
      @"SLPM-86361" : @2, // Tokimeki Memorial Drama Series Vol. 2 - Irodori no Love Song (Japan) (Disc 1)
      @"SLPM-86362" : @2, // Tokimeki Memorial Drama Series Vol. 2 - Irodori no Love Song (Japan) (Disc 2)
      @"SLPM-86224" : @2, // Tokimeki Memorial Drama Series Vol. 3 - Tabidachi no Uta (Japan) (Disc 1)
      @"SLPM-86225" : @2, // Tokimeki Memorial Drama Series Vol. 3 - Tabidachi no Uta (Japan) (Disc 2)
      @"SLPS-03333" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 1) (You)
      @"SLPS-03334" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 2) (In)
      @"SLPS-03335" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 3) (Ja)
      @"SLPS-03330" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 1) (You) (Genteiban)
      @"SLPS-03331" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 2) (In) (Genteiban)
      @"SLPS-03332" : @3, // Tokyo Majin Gakuen - Gehouchou (Japan) (Disc 3) (Ja) (Genteiban)
      @"SLPS-01432" : @2, // Tokyo Majin Gakuen - Kenpuuchou (Japan) (Disc 1) (You)
      @"SLPS-01433" : @2, // Tokyo Majin Gakuen - Kenpuuchou (Japan) (Disc 2) (In)
      @"SLPS-00285" : @3, // Tokyo Shadow (Japan) (Disc 1)
      @"SLPS-00286" : @3, // Tokyo Shadow (Japan) (Disc 2)
      @"SLPS-00287" : @3, // Tokyo Shadow (Japan) (Disc 3)
      //@"SLPM-86196" : @2, // Tomb Raider III - Adventures of Lara Croft (Japan) (Disc 1) (Japanese Version)
      //@"SLPM-86197" : @2, // Tomb Raider III - Adventures of Lara Croft (Japan) (Disc 2) (International Version)
      @"SCPS-18007" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 1) (v1.0)
      @"SCPS-18008" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 2) (v1.0)
      @"SCPS-18009" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 1) (v1.1)
      @"SCPS-18010" : @2, // Tomoyasu Hotei - Stolen Song (Japan) (Disc 2) (v1.1)
      @"SLPS-01743" : @3, // True Love Story 2 (Japan) (Disc 1)
      @"SLPS-01744" : @3, // True Love Story 2 (Japan) (Disc 2)
      @"SLPS-01745" : @3, // True Love Story 2 (Japan) (Disc 3)
      @"SLPS-00846" : @3, // Unsolved, The - Hyper Science Adventure (Japan) (Disc 1)
      @"SLPS-00847" : @3, // Unsolved, The - Hyper Science Adventure (Japan) (Disc 2)
      @"SLPS-00848" : @3, // Unsolved, The - Hyper Science Adventure (Japan) (Disc 3)
      @"SLPM-86371" : @2, // Valkyrie Profile (Japan) (Disc 1) (v1.0)
      @"SLPM-86372" : @2, // Valkyrie Profile (Japan) (Disc 2) (v1.0)
      @"SLPM-86379" : @2, // Valkyrie Profile (Japan) (Disc 1) (v1.1) / (v1.2)
      @"SLPM-86380" : @2, // Valkyrie Profile (Japan) (Disc 2) (v1.1) / (v1.2)
      @"SLUS-01156" : @2, // Valkyrie Profile (USA) (Disc 1)
      @"SLUS-01179" : @2, // Valkyrie Profile (USA) (Disc 2)
      @"SLPS-00590" : @2, // Voice Paradice Excella (Japan) (Disc 1)
      @"SLPS-00591" : @2, // Voice Paradice Excella (Japan) (Disc 2)
      @"SLPS-01213" : @2, // Wangan Trial (Japan) (Disc 1)
      @"SLPS-01214" : @2, // Wangan Trial (Japan) (Disc 2)
      @"SCPS-10089" : @2, // Wild Arms - 2nd Ignition (Japan) (Disc 1) (v1.0) / (v1.1)
      @"SCPS-10090" : @2, // Wild Arms - 2nd Ignition (Japan) (Disc 2) (v1.0) / (v1.1)
      @"SCUS-94484" : @2, // Wild Arms 2 (USA) (Disc 1)
      @"SCUS-94498" : @2, // Wild Arms 2 (USA) (Disc 2)
      @"SLES-00074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 1)
      @"SLES-10074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 2)
      @"SLES-20074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 3)
      @"SLES-30074" : @4, // Wing Commander III - Heart of the Tiger (Europe) (Disc 4)
      @"SLES-00105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 1)
      @"SLES-10105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 2)
      @"SLES-20105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 3)
      @"SLES-30105" : @4, // Wing Commander III - Heart of the Tiger (Germany) (Disc 4)
      @"SLPS-00477" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 1)
      @"SLPS-00478" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 2)
      @"SLPS-00479" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 3)
      @"SLPS-00480" : @4, // Wing Commander III - Heart of the Tiger (Japan) (Disc 4)
      @"SLUS-00019" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 1)
      @"SLUS-00134" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 2)
      @"SLUS-00135" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 3)
      @"SLUS-00136" : @4, // Wing Commander III - Heart of the Tiger (USA) (Disc 4)
      @"SLES-00659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 1)
      @"SLES-10659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 2)
      @"SLES-20659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 3)
      @"SLES-30659" : @4, // Wing Commander IV - The Price of Freedom (Europe) (Disc 4)
      @"SLES-00660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 1)
      @"SLES-10660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 2)
      @"SLES-20660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 3)
      @"SLES-30660" : @4, // Wing Commander IV - The Price of Freedom (France) (Disc 4)
      @"SLES-00661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 1)
      @"SLES-10661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 2)
      @"SLES-20661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 3)
      @"SLES-30661" : @4, // Wing Commander IV - The Price of Freedom (Germany) (Disc 4)
      @"SLUS-00270" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 1)
      @"SLUS-00271" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 2)
      @"SLUS-00272" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 3)
      @"SLUS-00273" : @4, // Wing Commander IV - The Price of Freedom (USA) (Disc 4)
      @"SCES-01565" : @4, // X-Files, The (Europe) (Disc 1)
      @"SCES-11565" : @4, // X-Files, The (Europe) (Disc 2)
      @"SCES-21565" : @4, // X-Files, The (Europe) (Disc 3)
      @"SCES-31565" : @4, // X-Files, The (Europe) (Disc 4)
      @"SCES-01566" : @4, // X-Files, The (France) (Disc 1)
      @"SCES-11566" : @4, // X-Files, The (France) (Disc 2)
      @"SCES-21566" : @4, // X-Files, The (France) (Disc 3)
      @"SCES-31566" : @4, // X-Files, The (France) (Disc 4)
      @"SCES-01567" : @4, // X-Files, The (Germany) (Disc 1)
      @"SCES-11567" : @4, // X-Files, The (Germany) (Disc 2)
      @"SCES-21567" : @4, // X-Files, The (Germany) (Disc 3)
      @"SCES-31567" : @4, // X-Files, The (Germany) (Disc 4)
      @"SCES-01568" : @4, // X-Files, The (Italy) (Disc 1)
      @"SCES-11568" : @4, // X-Files, The (Italy) (Disc 2)
      @"SCES-21568" : @4, // X-Files, The (Italy) (Disc 3)
      @"SCES-31568" : @4, // X-Files, The (Italy) (Disc 4)
      @"SCES-01569" : @4, // X-Files, The (Spain) (Disc 1)
      @"SCES-11569" : @4, // X-Files, The (Spain) (Disc 2)
      @"SCES-21569" : @4, // X-Files, The (Spain) (Disc 3)
      @"SCES-31569" : @4, // X-Files, The (Spain) (Disc 4)
      @"SLUS-00915" : @4, // X-Files, The (USA) (Disc 1)
      @"SLUS-00949" : @4, // X-Files, The (USA) (Disc 2)
      @"SLUS-00950" : @4, // X-Files, The (USA) (Disc 3)
      @"SLUS-00951" : @4, // X-Files, The (USA) (Disc 4)
      @"SLPS-01160" : @2, // Xenogears (Japan) (Disc 1)
      @"SLPS-01161" : @2, // Xenogears (Japan) (Disc 2)
      @"SLUS-00664" : @2, // Xenogears (USA) (Disc 1)
      @"SLUS-00669" : @2, // Xenogears (USA) (Disc 2)
      @"SCPS-10053" : @2, // Yarudora Series Vol. 1 - Double Cast (Japan) (Disc 1)
      @"SCPS-10054" : @2, // Yarudora Series Vol. 1 - Double Cast (Japan) (Disc 2)
      @"SCPS-10056" : @2, // Yarudora Series Vol. 2 - Kisetsu o Dakishimete (Japan) (Disc 1)
      @"SCPS-10057" : @2, // Yarudora Series Vol. 2 - Kisetsu o Dakishimete (Japan) (Disc 2)
      @"SCPS-10067" : @2, // Yarudora Series Vol. 3 - Sampaguita (Japan) (Disc 1)
      @"SCPS-10068" : @2, // Yarudora Series Vol. 3 - Sampaguita (Japan) (Disc 2)
      @"SCPS-10069" : @2, // Yarudora Series Vol. 4 - Yukiwari no Hana (Japan) (Disc 1)
      @"SCPS-10070" : @2, // Yarudora Series Vol. 4 - Yukiwari no Hana (Japan) (Disc 2)
      @"SLUS-00716" : @2, // You Don't Know Jack (USA) (Disc 1)
      @"SLUS-00762" : @2, // You Don't Know Jack (USA) (Disc 2)
      @"SLPS-00715" : @2, // Zen Nihon GT Senshuken Max Rev. (Japan) (Disc 1)
      @"SLPS-00716" : @2, // Zen Nihon GT Senshuken Max Rev. (Japan) (Disc 2)
      @"SLPS-01657" : @2, // Zen Super Robot Taisen Denshi Daihyakka (Japan) (Disc 1)
      @"SLPS-01658" : @2, // Zen Super Robot Taisen Denshi Daihyakka (Japan) (Disc 2)
      @"SLPS-01326" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 1)
      @"SLPS-01327" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 2)
      @"SLPS-01328" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 3)
      @"SLPS-01329" : @4, // Zoku Hatsukoi Monogatari - Shuugaku Ryokou (Japan) (Disc 4)
      @"SLPS-02266" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 1)
      @"SLPS-02267" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 2)
      @"SLPS-02268" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 3)
      @"SLPS-02269" : @4, // Zoku Mikagura Shoujo Tanteidan - Kanketsuhen (Japan) (Disc 4)
      };

    // Check if multiple discs required
    if (multiDiscGames[[current ROMSerial]])
    {
        current->_isMultiDiscGame = YES;
        current->_multiDiscTotal = [[multiDiscGames objectForKey:[current ROMSerial]] intValue];
    }

    // Check if SBI file is required
    if (sbiRequiredGames[[current ROMSerial]])
    {
        current->_isSBIRequired = YES;
    }

    // Set multitap configuration if detected
    if (multiTapGames[[current ROMSerial]])
    {
        current->_multiTapPlayerCount = [[multiTapGames objectForKey:[current ROMSerial]] intValue];

        if([multiTap5PlayerPort2 containsObject:[current ROMSerial]])
            MDFNI_SetSetting("psx.input.pport2.multitap", "1"); // Enable multitap on PSX port 2
        else
        {
            MDFNI_SetSetting("psx.input.pport1.multitap", "1"); // Enable multitap on PSX port 1
            if(current->_multiTapPlayerCount > 5)
                MDFNI_SetSetting("psx.input.pport2.multitap", "1"); // Enable multitap on PSX port 2
        }
    }
}

- (id)init
{
    if((self = [super init]))
    {
        _current = self;

        _multiTapPlayerCount = 2;
        _allCueSheetFiles = [[NSMutableArray alloc] init];

        for(unsigned i = 0; i < 8; i++)
            _inputBuffer[i] = (uint32_t *) calloc(9, sizeof(uint32_t));
    }

    return self;
}

- (void)dealloc
{
    for(unsigned i = 0; i < 8; i++)
        free(_inputBuffer[i]);

    delete surf;
}

# pragma mark - Execution

static void emulation_run()
{
    GET_CURRENT_OR_RETURN();

    static int16_t sound_buf[0x10000];
    int32 rects[game->fb_height];
    rects[0] = ~0;

    EmulateSpecStruct spec = {0};
    spec.surface = surf;
    spec.SoundRate = current->_sampleRate;
    spec.SoundBuf = sound_buf;
    spec.LineWidths = rects;
    spec.SoundBufMaxSize = sizeof(sound_buf) / 2;
    spec.SoundVolume = 1.0;
    spec.soundmultiplier = 1.0;

    MDFNI_Emulate(&spec);

    current->_mednafenCoreTiming = current->_masterClock / spec.MasterCycles;

    if(current->_systemType == psx)
    {
        current->_videoWidth = rects[spec.DisplayRect.y];
        current->_videoOffsetX = spec.DisplayRect.x;
    }
    else if(game->multires)
    {
        current->_videoWidth = rects[spec.DisplayRect.y];
        current->_videoOffsetX = spec.DisplayRect.x;
    }
    else
    {
        current->_videoWidth = spec.DisplayRect.w;
        current->_videoOffsetX = spec.DisplayRect.x;
    }

    current->_videoHeight = spec.DisplayRect.h;
    current->_videoOffsetY = spec.DisplayRect.y;

    update_audio_batch(spec.SoundBuf, spec.SoundBufSize);
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    [[NSFileManager defaultManager] createDirectoryAtPath:[self batterySavesDirectoryPath] withIntermediateDirectories:YES attributes:nil error:NULL];

    // Parse number of discs in m3u
    if([[[path pathExtension] lowercaseString] isEqualToString:@"m3u"])
    {
        NSString *m3uString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@".*\\.cue|.*\\.ccd" options:NSRegularExpressionCaseInsensitive error:nil];
        NSUInteger numberOfMatches = [regex numberOfMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length)];

        NSLog(@"Loaded m3u containing %lu cue sheets or ccd", numberOfMatches);

        _maxDiscs = numberOfMatches;

        // Keep track of cue sheets for use with SBI files
        [regex enumerateMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            NSRange range = result.range;
            NSString *match = [m3uString substringWithRange:range];

            if([match containsString:@".cue"])
                [_allCueSheetFiles addObject:[m3uString substringWithRange:range]];
        }];
    }
    else if([[[path pathExtension] lowercaseString] isEqualToString:@"cue"])
    {
        NSString *filename = [path lastPathComponent];
        [_allCueSheetFiles addObject:filename];
    }

    if([[self systemIdentifier] isEqualToString:@"openemu.system.lynx"])
    {
        _systemType = lynx;

        _mednafenCoreModule = @"lynx";
        _mednafenCoreAspect = OEIntSizeMake(80, 51);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.ngp"])
    {
        _systemType = ngp;

        _mednafenCoreModule = @"ngp";
        _mednafenCoreAspect = OEIntSizeMake(20, 19);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.pce"] || [[self systemIdentifier] isEqualToString:@"openemu.system.pcecd"])
    {
        _systemType = pce;

        _mednafenCoreModule = @"pce";
        _mednafenCoreAspect = OEIntSizeMake(256 * (8.0/7.0), 240);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.pcfx"])
    {
        _systemType = pcfx;

        _mednafenCoreModule = @"pcfx";
        _mednafenCoreAspect = OEIntSizeMake(4, 3);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.psx"])
    {
        _systemType = psx;

        _mednafenCoreModule = @"psx";
        _mednafenCoreAspect = OEIntSizeMake(4, 3);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 44100;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.saturn"])
    {
        _systemType = ss;

        _mednafenCoreModule = @"ss";
        _mednafenCoreAspect = OEIntSizeMake(4, 3);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 44100;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.vb"])
    {
        _systemType = vb;

        _mednafenCoreModule = @"vb";
        _mednafenCoreAspect = OEIntSizeMake(12, 7);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }
    else if([[self systemIdentifier] isEqualToString:@"openemu.system.ws"])
    {
        _systemType = wswan;

        _mednafenCoreModule = @"wswan";
        _mednafenCoreAspect = OEIntSizeMake(14, 9);
        //_mednafenCoreAspect = OEIntSizeMake(game->nominal_width, game->nominal_height);
        _sampleRate         = 48000;
    }

    mednafen_init();

    game = MDFNI_LoadGame([_mednafenCoreModule UTF8String], [path UTF8String]);

    if(!game)
        return NO;

    // BGRA pixel format
    MDFN_PixelFormat pix_fmt(MDFN_COLORSPACE_RGB, 16, 8, 0, 24);
    surf = new MDFN_Surface(NULL, game->fb_width, game->fb_height, game->fb_width, pix_fmt);

    _masterClock = game->MasterClock >> 32;

    if (_systemType == pce)
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
        game->SetInput(1, "gamepad", (uint8_t *)_inputBuffer[1]);
        game->SetInput(2, "gamepad", (uint8_t *)_inputBuffer[2]);
        game->SetInput(3, "gamepad", (uint8_t *)_inputBuffer[3]);
        game->SetInput(4, "gamepad", (uint8_t *)_inputBuffer[4]);
    }
    else if (_systemType == pcfx)
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
        game->SetInput(1, "gamepad", (uint8_t *)_inputBuffer[1]);
    }
    else if (_systemType == psx)
    {
        NSLog(@"PSX serial: %@ player count: %d", [_current ROMSerial], _multiTapPlayerCount);

        // Check if loading a multi-disc game without m3u
        if(_isMultiDiscGame && ![[[path pathExtension] lowercaseString] isEqualToString:@"m3u"])
        {
            NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                NSLocalizedDescriptionKey : @"Required m3u file missing.",
                NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"This game requires multiple discs and must be loaded using a m3u file with all %lu discs.\n\nTo enable disc switching and ensure save files load across discs, it cannot be loaded as a single disc.\n\nFor more information, visit:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-multi-disc-game", _multiDiscTotal],
                }];

            *error = outErr;

            return NO;
        }

        // Handle required SBI files for games
        if(_isSBIRequired && _allCueSheetFiles.count && ([[[path pathExtension] lowercaseString] isEqualToString:@"cue"] || [[[path pathExtension] lowercaseString] isEqualToString:@"m3u"]))
        {
            NSURL *romPath = [NSURL fileURLWithPath:[path stringByDeletingLastPathComponent]];

            BOOL missingFileStatus = NO;
            NSUInteger missingFileCount = 0;
            NSMutableString *missingFilesList = [[NSMutableString alloc] init];

            // Build a path to SBI file and check if it exists
            for(NSString *cueSheetFile in _allCueSheetFiles)
            {
                NSString *extensionlessFilename = [cueSheetFile stringByDeletingPathExtension];
                NSURL *sbiFile = [romPath URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sbi"]];

                // Check if the required SBI files exist
                if(![sbiFile checkResourceIsReachableAndReturnError:nil])
                {
                    missingFileStatus = YES;
                    missingFileCount++;
                    [missingFilesList appendString:[NSString stringWithFormat:@"\"%@\"\n\n", extensionlessFilename]];
                }
            }
            // Alert the user of missing SBI files that are required for the game
            if(missingFileStatus)
            {
                NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                    NSLocalizedDescriptionKey : missingFileCount > 1 ? @"Required SBI files missing." : @"Required SBI file missing.",
                    NSLocalizedRecoverySuggestionErrorKey : missingFileCount > 1 ? [NSString stringWithFormat:@"To run this game you need SBI files for the discs:\n\n%@Drag and drop the required files onto the game library window and try again.\n\nFor more information, visit:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-sbi-file", missingFilesList] : [NSString stringWithFormat:@"To run this game you need a SBI file for the disc:\n\n%@Drag and drop the required file onto the game library window and try again.\n\nFor more information, visit:\nhttps://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games#q-i-have-a-sbi-file", missingFilesList],
                    }];

                *error = outErr;

                return NO;
            }
        }

        for(unsigned i = 0; i < _multiTapPlayerCount; i++)
            game->SetInput(i, "dualshock", (uint8_t *)_inputBuffer[i]);
    }
    else if (_systemType == ss)
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
        game->SetInput(1, "gamepad", (uint8_t *)_inputBuffer[1]);
        game->SetInput(12, "builtin", (uint8_t *)_inputBuffer[7]); // reset button status
    }
    else
    {
        game->SetInput(0, "gamepad", (uint8_t *)_inputBuffer[0]);
    }

    MDFNI_SetMedia(0, 2, 0, 0); // Disc selection API

    emulation_run();

    return YES;
}

- (void)executeFrame
{
    emulation_run();
}

- (void)resetEmulation
{
    if (_systemType == ss)
    {
        _inputBuffer[7][0] = 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            _inputBuffer[7][0] = 0;
        });
    }

    MDFNI_Reset();
}

- (void)stopEmulation
{
    MDFNI_CloseGame();

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return _mednafenCoreTiming ?: 60;
}

# pragma mark - Video

- (OEIntRect)screenRect
{
    return OEIntRectMake(_videoOffsetX, _videoOffsetY, _videoWidth, _videoHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(game->fb_width, game->fb_height);
}

- (OEIntSize)aspectSize
{
    return _mednafenCoreAspect;
}

- (const void *)videoBuffer
{
    return surf->pixels;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

# pragma mark - Audio

static size_t update_audio_batch(const int16_t *data, size_t frames)
{
    GET_CURRENT_OR_RETURN(frames);

    [[current ringBufferAtIndex:0] write:data maxLength:frames * [current channelCount] * 2];
    return frames;
}

- (double)audioSampleRate
{
    return _sampleRate ? _sampleRate : 48000;
}

- (NSUInteger)channelCount
{
    return game->soundchan;
}

# pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if(_systemType == ss)
        block(NO, nil);
    else
        block(MDFNI_SaveState(fileName.fileSystemRepresentation, "", NULL, NULL, NULL), nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if(_systemType == ss)
        block(NO, nil);
    else
        block(MDFNI_LoadState(fileName.fileSystemRepresentation, ""), nil);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
    MemoryStream stream(65536, false);
    MDFNSS_SaveSM(&stream, true);
    size_t length = stream.map_size();
    void *bytes = stream.map();

    if(length)
        return [NSData dataWithBytes:bytes length:length];

    if(outError) {
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError  userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
    }

    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    NSError *error;
    const void *bytes = [state bytes];
    size_t length = [state length];

    MemoryStream stream(length, -1);
    memcpy(stream.map(), bytes, length);
    MDFNSS_LoadSM(&stream, true);
    size_t serialSize = stream.map_size();

    if(serialSize != length)
    {
        error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                    code:OEGameCoreStateHasWrongSizeError
                                userInfo:@{
                                           NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                                           NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the save state does not have the right size, %lu expected, got: %ld.", serialSize, [state length]],
                                        }];
    }

    if(error)
    {
        if(outError)
        {
            *outError = error;
        }
        return false;
    }
    else
    {
        return true;
    }
}

# pragma mark - Input

// Map OE button order to Mednafen button order
const int LynxMap[] = { 6, 7, 4, 5, 0, 1, 3, 2 };
const int NGPMap[]  = { 0, 1, 2, 3, 4, 5, 6 };
const int PCEMap[]  = { 4, 6, 7, 5, 0, 1, 8, 9, 10, 11, 3, 2, 12 };
const int PCFXMap[] = { 8, 10, 11, 9, 0, 1, 2, 3, 4, 5, 7, 6 };
const int PSXMap[]  = { 4, 6, 7, 5, 12, 13, 14, 15, 10, 8, 1, 11, 9, 2, 3, 0, 16, 24, 23, 22, 21, 20, 19, 18, 17 };
const int SSMap[]   = { 4, 5, 6, 7, 10, 8, 9, 2, 1, 0, 15, 3, 11 };
const int VBMap[]   = { 9, 8, 7, 6, 4, 13, 12, 5, 3, 2, 0, 1, 10, 11 };
const int WSMap[]   = { 0, 2, 3, 1, 4, 6, 7, 5, 9, 10, 8, 11 };

- (oneway void)didPushLynxButton:(OELynxButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] |= 1 << LynxMap[button];
}

- (oneway void)didReleaseLynxButton:(OELynxButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] &= ~(1 << LynxMap[button]);
}

- (oneway void)didPushNGPButton:(OENGPButton)button;
{
    _inputBuffer[0][0] |= 1 << NGPMap[button];
}

- (oneway void)didReleaseNGPButton:(OENGPButton)button;
{
    _inputBuffer[0][0] &= ~(1 << NGPMap[button]);
}

- (oneway void)didPushPCEButton:(OEPCEButton)button forPlayer:(NSUInteger)player;
{
    if (button != OEPCEButtonMode) // Check for six button mode toggle
        _inputBuffer[player-1][0] |= 1 << PCEMap[button];
    else
        _inputBuffer[player-1][0] ^= 1 << PCEMap[button];
}

- (oneway void)didReleasePCEButton:(OEPCEButton)button forPlayer:(NSUInteger)player;
{
    if (button != OEPCEButtonMode)
        _inputBuffer[player-1][0] &= ~(1 << PCEMap[button]);
}

- (oneway void)didPushPCECDButton:(OEPCECDButton)button forPlayer:(NSUInteger)player;
{
    if (button != OEPCECDButtonMode) // Check for six button mode toggle
        _inputBuffer[player-1][0] |= 1 << PCEMap[button];
    else
        _inputBuffer[player-1][0] ^= 1 << PCEMap[button];
}

- (oneway void)didReleasePCECDButton:(OEPCECDButton)button forPlayer:(NSUInteger)player;
{
    if (button != OEPCECDButtonMode)
        _inputBuffer[player-1][0] &= ~(1 << PCEMap[button]);
}

- (oneway void)didPushPCFXButton:(OEPCFXButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] |= 1 << PCFXMap[button];
}

- (oneway void)didReleasePCFXButton:(OEPCFXButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] &= ~(1 << PCFXMap[button]);
}

- (oneway void)didPushSaturnButton:(OESaturnButton)button forPlayer:(NSUInteger)player
{
    _inputBuffer[player-1][0] |= 1 << SSMap[button];
}

- (oneway void)didReleaseSaturnButton:(OESaturnButton)button forPlayer:(NSUInteger)player
{
    _inputBuffer[player-1][0] &= ~(1 << SSMap[button]);
}

- (oneway void)didPushVBButton:(OEVBButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] |= 1 << VBMap[button];
}

- (oneway void)didReleaseVBButton:(OEVBButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] &= ~(1 << VBMap[button]);
}

- (oneway void)didPushWSButton:(OEWSButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] |= 1 << WSMap[button];
}

- (oneway void)didReleaseWSButton:(OEWSButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] &= ~(1 << WSMap[button]);
}

- (oneway void)didPushPSXButton:(OEPSXButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] |= 1 << PSXMap[button];
}

- (oneway void)didReleasePSXButton:(OEPSXButton)button forPlayer:(NSUInteger)player;
{
    _inputBuffer[player-1][0] &= ~(1 << PSXMap[button]);
}

- (oneway void)didMovePSXJoystickDirection:(OEPSXButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    // Fix the analog circle-to-square axis range conversion by scaling between a value of 1.00 and 1.50
    // We cannot use MDFNI_SetSetting("psx.input.port1.dualshock.axis_scale", "1.33") directly.
    // Background: https://mednafen.github.io/documentation/psx.html#Section_analog_range
    value *= 32767; // de-normalize
    double scaledValue = MIN(floor(0.5 + value * 1.33), 32767); // 30712 / cos(2*pi/8) / 32767 = 1.33

    int analogNumber = PSXMap[button] - 17;
    uint8_t *buf = (uint8_t *)_inputBuffer[player-1];
    *(uint16*)& buf[3 + analogNumber * 2] = scaledValue;
}

- (void)changeDisplayMode
{
    if (_systemType == vb)
    {
        switch (MDFN_IEN_VB::mednafenCurrentDisplayMode)
        {
            case 0: // (2D) red/black
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x000000);
                MDFN_IEN_VB::VIP_SetParallaxDisable(true);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 1: // (2D) white/black
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFFFFFF, 0x000000);
                MDFN_IEN_VB::VIP_SetParallaxDisable(true);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 2: // (2D) purple/black
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF00FF, 0x000000);
                MDFN_IEN_VB::VIP_SetParallaxDisable(true);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 3: // (3D) red/blue
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x0000FF);
                MDFN_IEN_VB::VIP_SetParallaxDisable(false);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 4: // (3D) red/cyan
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x00B7EB);
                MDFN_IEN_VB::VIP_SetParallaxDisable(false);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 5: // (3D) red/electric cyan
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x00FFFF);
                MDFN_IEN_VB::VIP_SetParallaxDisable(false);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 6: // (3D) red/green
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFF0000, 0x00FF00);
                MDFN_IEN_VB::VIP_SetParallaxDisable(false);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 7: // (3D) green/red
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0x00FF00, 0xFF0000);
                MDFN_IEN_VB::VIP_SetParallaxDisable(false);
                MDFN_IEN_VB::mednafenCurrentDisplayMode++;
                break;

            case 8: // (3D) yellow/blue
                MDFN_IEN_VB::VIP_SetAnaglyphColors(0xFFFF00, 0x0000FF);
                MDFN_IEN_VB::VIP_SetParallaxDisable(false);
                MDFN_IEN_VB::mednafenCurrentDisplayMode = 0;
                break;

            default:
                return;
                break;
        }
    }
}

- (void)setDisc:(NSUInteger)discNumber
{
    uint32_t index = discNumber - 1; // 0-based index
    MDFNI_SetMedia(0, 0, 0, 0); // open drive/eject disc

    // Open/eject needs a bit of delay, so wait 1 second until inserting new disc
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MDFNI_SetMedia(0, 2, index, 0); // close drive/insert disc (2 = close)
    });
}

- (NSUInteger)discCount
{
    return _maxDiscs ? _maxDiscs : 1;
}

@end
