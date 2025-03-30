#pragma once

#include <cstdint>

namespace devilution {

enum class HeroSpeech : uint8_t {
	ChamberOfBoneLore,
	HorazonsSanctumLore,
	GolemSpellLore,
	HorazonsCreatureOfFlameLore,
	MortaVespaGaieaInnuminoEvegeenJatanLuaGraton,
	GrimspikeLieutenantOfBelialLore,
	HorazonsJournal,
	YourDeathWillBeAvenged,
	RestInPeaceMyFriend,
	ValorLore,
	HallsOfTheBlindLore,
	WarlordOfBloodLore,
	ICantUseThisYet,
	ICantCarryAnymore,
	IHaveNoRoom,
	WhereWouldIPutThis,
	NoWay,
	NotAChance,
	IdNeverUseThis,
	IdHaveToEquipThat,
	ICantMoveThis,
	ICantMoveThisYet,
	ICantOpenThis,
	ICantOpenThisYet,
	ICantLiftThis,
	ICantLiftThisYet,
	ICantCastThatHere,
	ICantCastThatYet,
	ThatDidntDoAnything,
	ICanAlreadyDoThat,
	IDontNeedThat,
	IDontNeedToDoThat,
	IDontWantThat,
	IDontHaveASpellReady,
	NotEnoughMana,
	ThatWouldKillMe,
	ICantDoThat,
	No,
	Yes,
	ThatWontWork,
	ThatWontWorkHere,
	ThatWontWorkYet,
	ICantGetThereFromHere,
	ItsTooHeavy,
	ItsTooBig,
	JustWhatIWasLookingFor,
	IveGotABadFeelingAboutThis,
	GotMilk,
	ImNotThirsty,
	ImNoMilkmaid,
	ICouldBlowUpTheWholeVillage,
	YepThatsACowAlright,
	TooUghHeavy,
	InSpirituSanctum,
	PraedictumOtium,
	EfficioObitusUtInimicus,
	TheEnchantmentIsGone,
	OhTooEasy,
	BackToTheGrave,
	TimeToDie,
	ImNotImpressed,
	ImSorryDidIBreakYourConcentration,
	VengeanceIsMine,
	Die,
	Yeah,
	Ah,
	Phew,
	Argh,
	ArghClang,
	Aaaaargh,
	OofAh,
	HeavyBreathing,
	Oh,
	Wow,
	ThankTheLight,
	WhatWasThat,
	MmHmm,
	Hmm,
	UhHuh,
	TheSpiritsOfTheDeadAreNowAvenged,
	TheTownIsSafeFromTheseFoulSpawn,
	RestWellLeoricIllFindYourSon,
	YourMadnessEndsHereBetrayer,
	YoullLureNoMoreMenToTheirDeaths,
	ReturnToHeavenWarriorOfLight,
	ICanSeeWhyTheyFearThisWeapon,
	ThisMustBeWhatGriswoldWanted,
	INeedToGetThisToLachdanan,
	INeedToGetThisToGriswold,
	IveNeverBeenHereBefore,
	MayTheSpiritOfArkaineProtectMe,
	ThisIsAPlaceOfGreatPower,
	ThisBladeMustBeDestroyed,
	YourReignOfPainHasEnded,
	NowThatsOneBigMushroom,
	TheSmellOfDeathSurroundsMe,
	TheSanctityOfThisPlaceHasBeenFouled,
	ItsHotDownHere,
	IMustBeGettingClose,
	MaybeItsLockedFromTheInside,
	LooksLikeItsRustedShut,
	MaybeTheresAnotherWay,
	AuughUh,

	LAST = AuughUh
};

enum class SfxID : int16_t {
	Walk,
	ShootBow,
	CastSpell,
	Swing,
	Swing2,
	WarriorDeath,
	ShootBow2,
	ShootFireballBow,
	QuestDone,
	BarrelExpload,
	BarrelBreak,
	PodExpload,
	PodPop,
	UrnExpload,
	UrnBreak,
	ChestOpen,
	DoorClose,
	DoorOpen,
	ItemAnvilFlip,
	ItemAxeFlip,
	ItemBloodStoneFlip,
	ItemBodyPartFlip,
	ItemBookFlip,
	ItemBowFlip,
	ItemCapFlip,
	ItemArmorFlip,
	ItemLeatherFlip,
	ItemMushroomFlip,
	ItemPotionFlip,
	ItemRingFlip,
	ItemRockFlip,
	ItemScrollFlip,
	ItemShieldFlip,
	ItemSignFlip,
	ItemStaffFlip,
	ItemSwordFlip,
	ItemGold,
	ItemAnvil,
	ItemAxe,
	ItemBloodStone,
	ItemBodyPart,
	ItemBook,
	ItemBow,
	ItemCap,
	GrabItem,
	ItemArmor,
	ItemLeather,
	ItemMushroom,
	ItemPotion,
	ItemRing,
	ItemRock,
	ItemScroll,
	ItemShield,
	ItemSign,
	ItemStaff,
	ItemSword,
	OperateLever,
	OperateShrine,
	OperateShrine1,
	ReadBook,
	Sarcophagus,
	MenuMove,
	MenuSelect,
	TriggerTrap,
	CastFire,
	CastEscape,
	CastLightning,
	CastSkill,
	SpellEnd,
	CastHealing,
	SpellRepair,
	SpellAcid,
	SpellAcid1,
	SpellApocalypse,
	SpellBloodStar,
	SpellBloodStarHit,
	SpellBoneSpirit,
	SpellBoneSpiritHit,
	OperateCaldron,
	SpellChargedBolt,
	SpellDoomSerpents, // Unused
	SpellLightningHit,
	SpellElemental,
	SpellEtherealize,
	SpellFirebolt,
	SpellFireHit,
	SpellFlameWave,
	OperateFountain,
	SpellGolem,
	OperateGoatShrine,
	SpellGuardian,
	SpellHolyBolt,
	SpellInfravision,
	SpellInvisibility, // Unused
	SpellLightning,
	SpellManaShield,
	BigExplosion,
	SpellNova,
	SpellPuddle,
	SpellResurrect,
	SpellStoneCurse,
	SpellPortal,
	SpellInferno,
	SpellTrapDisarm,
	SpellTeleport,
	SpellFireWall,
	SpellLightningWall,
	Gillian1,
	Gillian2,
	Gillian3,
	Gillian4,
	Gillian5,
	Gillian6,
	Gillian7,
	Gillian8,
	Gillian9,
	Gillian10,
	Gillian11,
	Gillian12,
	Gillian13,
	Gillian14,
	Gillian15,
	Gillian16,
	Gillian17,
	Gillian18,
	Gillian19,
	Gillian20,
	Gillian21,
	Gillian22,
	Gillian23,
	Gillian24,
	Gillian25,
	Gillian26,
	Gillian27,
	Gillian28,
	Gillian29,
	Gillian30,
	Gillian31,
	Gillian32,
	Gillian33,
	Gillian34,
	Gillian35,
	Gillian36,
	Gillian37,
	Gillian38,
	Gillian39,
	Gillian40,
	Griswold1,
	Griswold2,
	Griswold3,
	Griswold4,
	Griswold5,
	Griswold6,
	Griswold7,
	Griswold8,
	Griswold9,
	Griswold10,
	Griswold12,
	Griswold13,
	Griswold14,
	Griswold15,
	Griswold16,
	Griswold17,
	Griswold18,
	Griswold19,
	Griswold20,
	Griswold21,
	Griswold22,
	Griswold23,
	Griswold24,
	Griswold25,
	Griswold26,
	Griswold27,
	Griswold28,
	Griswold29,
	Griswold30,
	Griswold31,
	Griswold32,
	Griswold33,
	Griswold34,
	Griswold35,
	Griswold36,
	Griswold37,
	Griswold38,
	Griswold39,
	Griswold40,
	Griswold41,
	Griswold42,
	Griswold43,
	Griswold44,
	Griswold45,
	Griswold46,
	Griswold47,
	Griswold48,
	Griswold49,
	Griswold50,
	Griswold51,
	Griswold52,
	Griswold53,
	Griswold55,
	Griswold56,
	Cow1,
	Cow2,
	Pig,
	WoundedTownsmanOld, // Unused
	Farnham1,
	Farnham2,
	Farnham3,
	Farnham4,
	Farnham5,
	Farnham6,
	Farnham7,
	Farnham8,
	Farnham9,
	Farnham10,
	Farnham11,
	Farnham12,
	Farnham13,
	Farnham14,
	Farnham15,
	Farnham16,
	Farnham17,
	Farnham18,
	Farnham19,
	Farnham20,
	Farnham21,
	Farnham22,
	Farnham23,
	Farnham24,
	Farnham25,
	Farnham26,
	Farnham27,
	Farnham28,
	Farnham29,
	Farnham30,
	Farnham31,
	Farnham32,
	Farnham33,
	Farnham34,
	Farnham35,
	Pepin1,
	Pepin2,
	Pepin3,
	Pepin4,
	Pepin5,
	Pepin6,
	Pepin7,
	Pepin8,
	Pepin9,
	Pepin10,
	Pepin11,
	Pepin12,
	Pepin13,
	Pepin14,
	Pepin15,
	Pepin16,
	Pepin17,
	Pepin18,
	Pepin19,
	Pepin20,
	Pepin21,
	Pepin22,
	Pepin23,
	Pepin24,
	Pepin25,
	Pepin26,
	Pepin27,
	Pepin28,
	Pepin29,
	Pepin30,
	Pepin31,
	Pepin32,
	Pepin33,
	Pepin34,
	Pepin35,
	Pepin36,
	Pepin37,
	Pepin38,
	Pepin39,
	Pepin40,
	Pepin41,
	Pepin42,
	Pepin43,
	Pepin44,
	Pepin45,
	Pepin46,
	Pepin47,
	Wirt1,
	Wirt2,
	Wirt3,
	Wirt4,
	Wirt5,
	Wirt6,
	Wirt7,
	Wirt8,
	Wirt9,
	Wirt10,
	Wirt11,
	Wirt12,
	Wirt13,
	Wirt14,
	Wirt15,
	Wirt16,
	Wirt17,
	Wirt18,
	Wirt19,
	Wirt20,
	Wirt21,
	Wirt22,
	Wirt23,
	Wirt24,
	Wirt25,
	Wirt26,
	Wirt27,
	Wirt28,
	Wirt29,
	Wirt30,
	Wirt31,
	Wirt32,
	Wirt33,
	Wirt34,
	Wirt35,
	Wirt36,
	Wirt37,
	Wirt38,
	Wirt39,
	Wirt40,
	Wirt41,
	Wirt42,
	Wirt43,
	Tremain0, // Unused
	Tremain1, // Unused
	Tremain2, // Unused
	Tremain3, // Unused
	Tremain4, // Unused
	Tremain5, // Unused
	Tremain6, // Unused
	Tremain7, // Unused
	Cain0,
	Cain1,
	Cain2,
	Cain3,
	Cain4,
	Cain5,
	Cain6,
	Cain7,
	Cain8,
	Cain9,
	Cain10,
	Cain11,
	Cain12,
	Cain13,
	Cain14,
	Cain15,
	Cain16,
	Cain17,
	Cain18,
	Cain19,
	Cain20,
	Cain21,
	Cain22,
	Cain23,
	Cain24,
	Cain25,
	Cain26,
	Cain27,
	Cain28,
	Cain29,
	Cain30,
	Cain31,
	Cain33,
	Cain34,
	Cain35,
	Cain36,
	Cain37,
	Cain38,
	Ogden0,
	Ogden1,
	Ogden2,
	Ogden3,
	Ogden4,
	Ogden5,
	Ogden6,
	Ogden7,
	Ogden8,
	Ogden9,
	Ogden10,
	Ogden11,
	Ogden12,
	Ogden13,
	Ogden14,
	Ogden15,
	Ogden16,
	Ogden17,
	Ogden18,
	Ogden19,
	Ogden20,
	Ogden21,
	Ogden22,
	Ogden23,
	Ogden24,
	Ogden25,
	Ogden26,
	Ogden27,
	Ogden28,
	Ogden29,
	Ogden30,
	Ogden31,
	Ogden32,
	Ogden33,
	Ogden34,
	Ogden35,
	Ogden36,
	Ogden37,
	Ogden38,
	Ogden39,
	Ogden40,
	Ogden41,
	Ogden43,
	Ogden44,
	Ogden45,
	Adria1,
	Adria2,
	Adria3,
	Adria4,
	Adria5,
	Adria6,
	Adria7,
	Adria8,
	Adria9,
	Adria10,
	Adria11,
	Adria12,
	Adria13,
	Adria14,
	Adria15,
	Adria16,
	Adria17,
	Adria18,
	Adria19,
	Adria20,
	Adria21,
	Adria22,
	Adria23,
	Adria24,
	Adria25,
	Adria26,
	Adria27,
	Adria28,
	Adria29,
	Adria30,
	Adria31,
	Adria32,
	Adria33,
	Adria34,
	Adria35,
	Adria36,
	Adria37,
	Adria38,
	Adria39,
	Adria40,
	Adria41,
	Adria42,
	Adria43,
	Adria44,
	Adria45,
	Adria46,
	Adria47,
	Adria48,
	Adria49,
	Adria50,
	WoundedTownsman,
	Sorceror1,
	Sorceror2,
	Sorceror3,
	Sorceror4,
	Sorceror5,
	Sorceror6,
	Sorceror7,
	Sorceror8,
	Sorceror9,
	Sorceror10,
	Sorceror11,
	Sorceror12,
	Sorceror13,
	Sorceror14,
	Sorceror15,
	Sorceror16,
	Sorceror17,
	Sorceror18,
	Sorceror19,
	Sorceror20,
	Sorceror21,
	Sorceror22,
	Sorceror23,
	Sorceror24,
	Sorceror25,
	Sorceror26,
	Sorceror27,
	Sorceror28,
	Sorceror29,
	Sorceror30,
	Sorceror31,
	Sorceror32,
	Sorceror33,
	Sorceror34,
	Sorceror35,
	Sorceror36,
	Sorceror37,
	Sorceror38,
	Sorceror39,
	Sorceror40,
	Sorceror41,
	Sorceror42,
	Sorceror43,
	Sorceror44,
	Sorceror45,
	Sorceror46,
	Sorceror47,
	Sorceror48,
	Sorceror49,
	Sorceror50,
	Sorceror51,
	Sorceror52,
	Sorceror53,
	Sorceror54,
	Sorceror55,
	Sorceror56,
	Sorceror57,
	Sorceror58,
	Sorceror59,
	Sorceror60,
	Sorceror61,
	Sorceror62,
	Sorceror63,
	Sorceror64,
	Sorceror65,
	Sorceror66,
	Sorceror67,
	Sorceror68,
	Sorceror69,
	Sorceror69b,
	Sorceror70,
	Sorceror71,
	Sorceror72,
	Sorceror73,
	Sorceror74,
	Sorceror75,
	Sorceror76,
	Sorceror77,
	Sorceror78,
	Sorceror79,
	Sorceror80,
	Sorceror81,
	Sorceror82,
	Sorceror83,
	Sorceror84,
	Sorceror85,
	Sorceror86,
	Sorceror87,
	Sorceror88,
	Sorceror89,
	Sorceror90,
	Sorceror91,
	Sorceror92,
	Sorceror93,
	Sorceror94,
	Sorceror95,
	Sorceror96,
	Sorceror97,
	Sorceror98,
	Sorceror99,
	Sorceror100,
	Sorceror101,
	Sorceror102,
	Rogue1,
	Rogue2,
	Rogue3,
	Rogue4,
	Rogue5,
	Rogue6,
	Rogue7,
	Rogue8,
	Rogue9,
	Rogue10,
	Rogue11,
	Rogue12,
	Rogue13,
	Rogue14,
	Rogue15,
	Rogue16,
	Rogue17,
	Rogue18,
	Rogue19,
	Rogue20,
	Rogue21,
	Rogue22,
	Rogue23,
	Rogue24,
	Rogue25,
	Rogue26,
	Rogue27,
	Rogue28,
	Rogue29,
	Rogue30,
	Rogue31,
	Rogue32,
	Rogue33,
	Rogue34,
	Rogue35,
	Rogue36,
	Rogue37,
	Rogue38,
	Rogue39,
	Rogue40,
	Rogue41,
	Rogue42,
	Rogue43,
	Rogue44,
	Rogue45,
	Rogue46,
	Rogue47,
	Rogue48,
	Rogue49,
	Rogue50,
	Rogue51,
	Rogue52,
	Rogue53,
	Rogue54,
	Rogue55,
	Rogue56,
	Rogue57,
	Rogue58,
	Rogue59,
	Rogue60,
	Rogue61,
	Rogue62,
	Rogue63,
	Rogue64,
	Rogue65,
	Rogue66,
	Rogue67,
	Rogue68,
	Rogue69,
	Rogue69b,
	Rogue70,
	Rogue71,
	Rogue72,
	Rogue73,
	Rogue74,
	Rogue75,
	Rogue76,
	Rogue77,
	Rogue78,
	Rogue79,
	Rogue80,
	Rogue81,
	Rogue82,
	Rogue83,
	Rogue84,
	Rogue85,
	Rogue86,
	Rogue87,
	Rogue88,
	Rogue89,
	Rogue90,
	Rogue91,
	Rogue92,
	Rogue93,
	Rogue94,
	Rogue95,
	Rogue96,
	Rogue97,
	Rogue98,
	Rogue99,
	Rogue100,
	Rogue101,
	Rogue102,
	Warrior1,
	Warrior2,
	Warrior3,
	Warrior4,
	Warrior5,
	Warrior6,
	Warrior7,
	Warrior8,
	Warrior9,
	Warrior10,
	Warrior11,
	Warrior12,
	Warrior13,
	Warrior14,
	Warrior14b,
	Warrior14c,
	Warrior15,
	Warrior15b,
	Warrior15c,
	Warrior16,
	Warrior16b,
	Warrior16c,
	Warrior17,
	Warrior18,
	Warrior19,
	Warrior20,
	Warrior21,
	Warrior22,
	Warrior23,
	Warrior24,
	Warrior25,
	Warrior26,
	Warrior27,
	Warrior28,
	Warrior29,
	Warrior30,
	Warrior31,
	Warrior32,
	Warrior33,
	Warrior34,
	Warrior35,
	Warrior36,
	Warrior37,
	Warrior38,
	Warrior39,
	Warrior40,
	Warrior41,
	Warrior42,
	Warrior43,
	Warrior44,
	Warrior45,
	Warrior46,
	Warrior47,
	Warrior48,
	Warrior49,
	Warrior50,
	Warrior51,
	Warrior52,
	Warrior53,
	Warrior54,
	Warrior55,
	Warrior56,
	Warrior57,
	Warrior58,
	Warrior59,
	Warrior60,
	Warrior61,
	Warrior62,
	Warrior63,
	Warrior64,
	Warrior65,
	Warrior66,
	Warrior67,
	Warrior68,
	Warrior69,
	Warrior69b,
	Warrior70,
	Warrior71,
	Warrior72,
	Warrior73,
	Warrior74,
	Warrior75,
	Warrior76,
	Warrior77,
	Warrior78,
	Warrior79,
	Warrior80,
	Warrior81,
	Warrior82,
	Warrior83,
	Warrior84,
	Warrior85,
	Warrior86,
	Warrior87,
	Warrior88,
	Warrior89,
	Warrior90,
	Warrior91,
	Warrior92,
	Warrior93,
	Warrior94,
	Warrior95,
	Warrior96b,
	Warrior97,
	Warrior98,
	Warrior99,
	Warrior100,
	Warrior101,
	Warrior102,
	Monk1,
	Monk8,
	Monk9,
	Monk10,
	Monk11,
	Monk12,
	Monk13,
	Monk14,
	Monk15,
	Monk16,
	Monk24,
	Monk27,
	Monk29,
	Monk34,
	Monk35,
	Monk43,
	Monk46,
	Monk49,
	Monk50,
	Monk52,
	Monk54,
	Monk55,
	Monk56,
	Monk61,
	Monk62,
	Monk68,
	Monk69,
	Monk69b,
	Monk70,
	Monk71,
	Monk79,
	Monk80,
	Monk82,
	Monk83,
	Monk87,
	Monk88,
	Monk89,
	Monk91,
	Monk92,
	Monk94,
	Monk95,
	Monk96,
	Monk97,
	Monk98,
	Monk99,
	Narrator1,
	Narrator2,
	Narrator3,
	Narrator4,
	Narrator5,
	Narrator6,
	Narrator7,
	Narrator8,
	Narrator9,
	DiabloGreeting,
	ButcherGreeting,
	Gharbad1,
	Gharbad2,
	Gharbad3,
	Gharbad4,
	Lachdanan1,
	Lachdanan2,
	Lachdanan3,
	LazarusGreeting,
	LeoricGreeting,
	Snotspill1,
	Snotspill2,
	Snotspill3,
	Warlord,
	Zhar1,
	Zhar2,
	DiabloDeath,
	Farmer1,
	Farmer2,
	Farmer2a,
	Farmer3,
	Farmer4,
	Farmer5,
	Farmer6,
	Farmer7,
	Farmer8,
	Farmer9,
	Celia1,
	Celia2,
	Celia3,
	Celia4,
	Defiler1,
	Defiler2,
	Defiler3,
	Defiler4,
	Defiler8,
	Defiler6,
	Defiler7,
	NaKrul1,
	NaKrul2,
	NaKrul3,
	NaKrul4,
	NaKrul5,
	NaKrul6,
	NarratorHF3,
	CompleteNut1,
	CompleteNut2,
	CompleteNut3,
	CompleteNut4,
	CompleteNut4a,
	CompleteNut5,
	CompleteNut6,
	CompleteNut7,
	CompleteNut8,
	CompleteNut9,
	CompleteNut10,
	CompleteNut11,
	CompleteNut12,
	NarratorHF6,
	NarratorHF7,
	NarratorHF8,
	NarratorHF5,
	NarratorHF9,
	NarratorHF4,
	CryptDoorOpen,
	CryptDoorClose,

	LAST = CryptDoorClose,
	None = -1,
};

enum sfx_flag : uint8_t {
	// clang-format off
	sfx_STREAM   = 1 << 0,
	sfx_MISC     = 1 << 1,
	sfx_UI       = 1 << 2,
	sfx_MONK     = 1 << 3,
	sfx_ROGUE    = 1 << 4,
	sfx_WARRIOR  = 1 << 5,
	sfx_SORCERER = 1 << 6,
	sfx_HELLFIRE = 1 << 7,
	// clang-format on
};

} // namespace devilution
