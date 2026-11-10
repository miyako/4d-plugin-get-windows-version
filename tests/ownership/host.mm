#include "4DPluginAPI.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>

static std::map<PA_Unichar *, size_t> strings;
static std::map<PA_Handle, size_t> handles;
static std::map<PA_Picture, int> pictures;
static bool nullEmpty = false;
static bool failHandle = false;
static bool failPicture = false;
static bool commandError = false;
static bool owningResult = false;
static bool pictureResult = false;
static CUTF16String expectedText;
static int commands = 0;

static void check(bool ok, const char *message)
{
	if(!ok) {
		std::fprintf(stderr, "ownership assertion: %s\n", message);
		std::abort();
	}
}

static PA_Unistring makeString(const PA_Unichar *text)
{
	size_t n = 0;
	if(text)
		while(text[n]) ++n;
	PA_Unistring value = {};
	value.fLength = static_cast<PA_long32>(n);
	if(n || !nullEmpty) {
		value.fString = static_cast<PA_Unichar *>(std::malloc((n + 1) * sizeof(PA_Unichar)));
		check(value.fString != nullptr, "host allocation");
		if(n) std::memcpy(value.fString, text, n * sizeof(PA_Unichar));
		value.fString[n] = 0;
		PA_Unichar *buffer = value.fString;
		strings[buffer] = n;
	}
	return value;
}

static void verifyString(PA_Unistring value, const CUTF16String &expected)
{
	check(value.fLength == expected.size(), "exact UTF16 code-unit count");
	if(value.fString) {
		PA_Unichar *buffer = value.fString;
		auto found = strings.find(buffer);
		check(found != strings.end(), "string is live");
		check(found->second == expected.size(), "allocation length");
		check(value.fString[value.fLength] == 0, "terminator in capacity");
		check(CUTF16String(value.fString, value.fLength) == expected, "exact text");
	} else {
		check(expected.empty(), "null only represents empty");
	}
}

static void freeString(PA_Unistring value)
{
	if(!value.fString) return;
	PA_Unichar *buffer = value.fString;
	check(strings.erase(buffer) == 1, "path alias disposed twice");
	std::free(value.fString);
}

static PA_Picture newPicture()
{
	PA_Picture value = std::malloc(1);
	check(value != nullptr, "picture allocation");
	pictures[value] = 1;
	return value;
}

static void releasePicture(PA_Picture value)
{
	if(!value) return;
	auto found = pictures.find(value);
	check(found != pictures.end() && found->second > 0, "picture owner live");
	if(--found->second == 0) {
		pictures.erase(found);
		std::free(value);
	}
}

static void clear(PA_Variable *value)
{
	switch(value->fType) {
		case eVK_Unistring: freeString(value->uValue.fString); break;
		case eVK_Picture: releasePicture(value->uValue.fPicture); break;
		case eVK_ArrayUnicode: {
			PA_Handle h = value->uValue.fArray.fData;
			if(h) {
				check(handles.count(h), "array handle live");
				auto data = reinterpret_cast<PA_Unistring *>(*h);
				for(int i = 0; i <= value->uValue.fArray.fNbElements; ++i)
					freeString(data[i]);
				PA_DisposeHandle(h);
			}
			break;
		}
		case eVK_Undefined:
		case eVK_Longint: break;
		default: check(false, "invalid sentinel must not be cleared");
	}
	*value = {};
	value->fType = eVK_Undefined;
}

static void host(short selector, EngineBlock *eb)
{
	switch(selector) {
		case EX_CREATE_UNISTRING:
			eb->fUniString1 = makeString(reinterpret_cast<PA_Unichar *>(eb->fHandle));
			break;
		case EX_DISPOSE_UNISTRING: freeString(eb->fUniString1); break;
		case EX_SET_UNISTRING: {
			PA_Unistring replacement = makeString(reinterpret_cast<PA_Unichar *>(eb->fHandle));
			freeString(eb->fUniString1);
			eb->fUniString1 = replacement;
			break;
		}
		case EX_CLEAR_VARIABLE: clear(static_cast<PA_Variable *>(eb->fPtr1)); break;
		case EX_HANDLE_MANAGER: {
			eb->fError = 0;
			// SDK structures are packed to two bytes; maps need aligned keys.
			PA_Handle handle = eb->fParam1 == 1 ? nullptr : eb->fHandle;
			switch(eb->fParam1) {
				case 1:
					if(failHandle) {
						failHandle = false;
						eb->fHandle = nullptr;
						eb->fError = eER_IncompatibleTypes;
					} else {
						auto h = static_cast<PA_Handle>(std::malloc(sizeof(char *)));
						*h = static_cast<char *>(std::calloc(1, eb->fParam2 ? eb->fParam2 : 1));
						handles[h] = eb->fParam2;
						eb->fHandle = h;
					}
					break;
				case 2:
					check(handles.erase(handle) == 1, "handle freed once");
					std::free(*eb->fHandle);
					std::free(eb->fHandle);
					break;
				case 3: {
					check(handles.count(handle), "resize handle live");
					size_t old = handles.at(handle);
					*eb->fHandle = static_cast<char *>(std::realloc(*eb->fHandle, eb->fParam2));
					check(*eb->fHandle != nullptr, "host resize");
					if(eb->fParam2 > old)
						std::memset(*eb->fHandle + old, 0, eb->fParam2 - old);
					handles[handle] = eb->fParam2;
					break;
				}
				case 4: eb->fParam2 = handles.at(handle); break;
				case 5: eb->fParam3 = handle ? reinterpret_cast<sLONG_PTR>(*handle) : 0; break;
				case 6: break;
				default: check(false, "unexpected handle operation");
			}
			break;
		}
		case EX_CREATE_PICTURE:
			eb->fPicture = failPicture ? nullptr : newPicture();
			eb->fError = failPicture ? eER_IncompatibleTypes : 0;
			failPicture = false;
			break;
		case EX_DISPOSE_PICTURE: releasePicture(eb->fPicture); break;
		case EX_DUPLICATE_PICTURE: {
			PA_Picture picture = eb->fPicture;
			check(pictures.count(picture), "retain live picture");
			if(eb->fParam1 == 0) ++pictures.at(picture);
			else eb->fPicture = newPicture();
			break;
		}
		case EX_GET_PICTURE_DATA: {
			PA_Picture picture = eb->fPicture;
			check(pictures.count(picture), "metadata picture live");
			// No representations: failed output is deliberately poisoned.
			std::memset(&eb->fUniString1, 0xa5, sizeof(eb->fUniString1));
			eb->fError = eER_IncompatibleTypes;
			break;
		}
		case EX_CONVERT_CHARSET_TO_CHARSET: {
			check(eb->fParam2 == eVTC_UTF_8 && eb->fParam4 == eVTC_UTF_16,
				  "conversion direction");
			CFStringRef text = CFStringCreateWithBytes(kCFAllocatorDefault,
				static_cast<const UInt8 *>(eb->fPtr1), eb->fParam1, kCFStringEncodingUTF8, false);
			check(text != nullptr, "valid synthetic UTF8");
			CFIndex units = CFStringGetLength(text);
			check(eb->fParam3 >= units * sizeof(PA_Unichar), "conversion capacity is bytes");
			CFStringGetCharacters(text, CFRangeMake(0, units), static_cast<UniChar *>(eb->fPtr2));
			// The API returns bytes excluding the terminator, not code units.
			eb->fParam3 = units * sizeof(PA_Unichar);
			eb->fError = 0;
			CFRelease(text);
			break;
		}
		case EX_EXECUTE_COMMAND_BY_ID: {
			++commands;
			auto args = static_cast<PA_Variable **>(eb->fPtr1);
			auto result = static_cast<PA_Variable *>(eb->fPtr2);
			eb->fError = commandError ? eER_IncompatibleTypes : 0;
			if(!commandError) {
				PA_Picture input = eb->fParam1 == 678 ? nullptr : args[0]->uValue.fPicture;
				switch(eb->fParam1) {
					case 678:
						verifyString(args[0]->uValue.fString, expectedText);
						check(args[1]->fType == eVK_Picture, "typed output destination");
						PA_ClearVariable(args[1]);
						PA_SetPictureVariable(args[1], newPicture());
						break;
					case 1002:
						verifyString(args[1]->uValue.fString, expectedText);
						[[fallthrough]];
					case 988:
						check(pictures.count(input), "synchronous picture input");
						if(expectedText.size() == 5) {
							PA_ClearVariable(args[0]);
							PA_SetPictureVariable(args[0], newPicture());
						}
						break;
					case 457:
						check(pictures.count(input), "borrowed input survives");
						PA_SetLongintVariable(args[1], 17);
						PA_SetLongintVariable(args[2], 23);
						break;
					case 679:
						check(pictures.count(input), "thumbnail input");
						PA_ClearVariable(args[1]);
						PA_SetPictureVariable(args[1], newPicture());
						break;
					default: check(false, "unexpected command");
				}
			}
			if(pictureResult) {
				PA_SetPictureVariable(result, newPicture());
			} else if(owningResult) {
				PA_Unichar text[] = {'r', 0x03a9, 0xd83d, 0xde00, 0};
				PA_Unistring value = makeString(text);
				PA_SetStringVariable(result, &value);
			}
			break;
		}
		default: check(false, "unexpected engine selector");
	}
}

static CUTF16String utf16(const char *text)
{
	C_TEXT value;
	CUTF8String input(reinterpret_cast<const uint8_t *>(text));
	value.setUTF8String(&input);
	CUTF16String result;
	value.copyUTF16String(&result);
	return result;
}

static void balanced(const char *name)
{
	check(strings.empty(), name);
	check(handles.empty(), "all handles balanced");
	check(pictures.empty(), "all picture references balanced");
}

static void pictureCase(const std::string &name)
{
	const char *fixtures[] = {"ASCII", "\xce\xa9", "\xf0\x9f\x98\x80", ""};
	for(const char *fixture : fixtures) {
		expectedText = utf16(fixture);
		PA_Picture handoff = nullptr;
		{
			CPicture value;
			if(name == "path") {
				CUTF8String path(reinterpret_cast<const uint8_t *>(fixture));
				value.fromFileAtPath(&path);
			} else if(name == "bytes") {
				const uint8_t bytes[] = {1, 2, 3};
				value.setBytes(bytes, sizeof(bytes));
				value.setBytes(bytes, sizeof(bytes));
			} else if(name == "copy-units") {
				handoff = value.createCopy(fixture);
			} else if(name == "gray-owners") {
				handoff = value.createGrayScale();
			} else if(name == "command-result") {
				owningResult = true;
				unsigned int width = 0, height = 0;
				value.getSize(&width, &height);
				check(width == 17 && height == 23, "scalar outputs copied");
			} else if(name == "handoffs") {
				handoff = value.createThumbnail(17, 23);
				PA_Picture destination = PA_CreatePicture(nullptr, 0);
				BytePtr params[] = {reinterpret_cast<BytePtr>(&destination)};
				value.toParamAtIndex(params, 1);
				value.toParamAtIndex(params, 1);
				PA_DisposePicture(destination);
				PA_Picture returned = nullptr;
				value.setReturn(reinterpret_cast<sLONG_PTR *>(&returned));
				PA_DisposePicture(returned);
			} else if(name == "failure") {
				commandError = true;
				owningResult = true;
				handoff = value.createThumbnail(17, 23);
				check(pictures.count(handoff), "failed command retains initialized output");
				commandError = false;
				failHandle = true;
				int before = commands;
				unsigned int width = 1, height = 1;
				value.getSize(&width, &height);
				check(commands == before && width == 0 && height == 0, "raw-kind-zero command failure");
				check(pictures.count(value.getPicture()), "failure preserves borrowed owner");
			} else if(name == "picture-result") {
				pictureResult = true;
				handoff = value.createGrayScale();
			} else if(name == "borrowed-param") {
				PA_Picture input = PA_CreatePicture(nullptr, 0);
				BytePtr params[] = {reinterpret_cast<BytePtr>(&input)};
				value.fromParamAtIndex(params, 1);
				PA_DisposePicture(input);
				unsigned int width = 0, height = 0;
				value.getSize(&width, &height);
				check(width == 17 && height == 23, "retained borrowed input");
			} else if(name == "picture-create-failure") {
				PA_Picture original = value.getPicture();
				failPicture = true;
				const uint8_t bytes[] = {1};
				value.setBytes(bytes, sizeof(bytes));
				check(PA_GetLastError() == eER_IncompatibleTypes, "creation error remains observable");
				check(value.getPicture() == original, "failed creation preserves original owner");
			} else {
				check(false, "unknown picture test");
			}
			check(pictures.count(value.getPicture()), "wrapper owns live picture");
		}
		if(handoff) {
			check(pictures.count(handoff), "owning handoff survives wrapper destruction");
			PA_DisposePicture(handoff);
		}
		balanced(name.c_str());
	}
}

static void arrays()
{
	const char *fixtures[] = {"ASCII", "\xce\xa9", "\xf0\x9f\x98\x80", ""};
	PA_Variable destination = PA_CreateVariable(eVK_Undefined);
	BytePtr params[] = {reinterpret_cast<BytePtr>(&destination)};
	ARRAY_TEXT source;
	source.setSize(1);
	for(const char *fixture : fixtures) {
		CUTF16String text = utf16(fixture);
		source.appendUTF16String(&text);
	}
	source.toParamAtIndex(params, 1);
	ARRAY_TEXT snapshot;
	snapshot.fromParamAtIndex(params, 1);
	source.toParamAtIndex(params, 1);
	for(int i = 0; i < 128; ++i) {
		PA_Unichar churn[] = {'c', 'h', 'u', 'r', 'n', 0};
		PA_Unistring temporary = PA_CreateUnistring(churn);
		PA_DisposeUnistring(&temporary);
	}
	for(int i = 0; i < 4; ++i) {
		CUTF16String text = utf16(fixtures[i]), copied;
		snapshot.copyUTF16StringAtIndex(&copied, i + 1);
		check(text == copied, "borrowed input copied before replacement");
		verifyString(PA_GetStringInArray(destination, i + 1), text);
	}
	PA_Unichar content[] = {'x', 0x03a9, 0xd83d, 0xde00, 0};
	PA_Unistring first = PA_CreateUnistring(content), second = PA_CreateUnistring(content);
	check(first.fString != second.fString, "independent allocations for independent outputs");
	PA_SetStringInArray(destination, 0, &first);
	PA_SetStringInArray(destination, 1, &second);
	verifyString(PA_GetStringInArray(destination, 0), CUTF16String(content));
	PA_Unistring rejected = PA_CreateUnistring(content);
	PA_Variable wrong = PA_CreateVariable(eVK_Longint);
	PA_SetStringInArray(wrong, 0, &rejected);
	PA_SetStringInArray(destination, -1, &rejected);
	PA_SetStringInArray(destination, 99, &rejected);
	PA_Variable noData = destination;
	noData.uValue.fArray.fData = nullptr;
	PA_SetStringInArray(noData, 0, &rejected);
	PA_SetStringInArray(destination, 0, nullptr);
	verifyString(rejected, CUTF16String(content));
	PA_DisposeUnistring(&rejected);
	PA_ResizeArray(&destination, 0);
	verifyString(PA_GetStringInArray(destination, 0), CUTF16String(content));
	PA_ClearVariable(&destination);
	balanced("array transfers and rejection guards");
}

static void scalars()
{
	const char *fixtures[] = {"ASCII", "\xce\xa9", "\xf0\x9f\x98\x80", ""};
	for(const char *fixture : fixtures) {
		PA_Unistring result = makeString(nullptr);
		PA_Unistring *slot = &result;
		{
			C_TEXT value;
			CUTF8String input(reinterpret_cast<const uint8_t *>(fixture));
			value.setUTF8String(&input);
			value.setReturn(reinterpret_cast<sLONG_PTR *>(&slot));
		}
		verifyString(result, utf16(fixture));
		PA_DisposeUnistring(&result);
	}
	PA_Unistring result = makeString(nullptr);
	PA_Unistring *slot = &result;
	int option = 1;
	BytePtr params[] = {reinterpret_cast<BytePtr>(&option)};
	void *data = nullptr;
	FourDPackex(2, params, &data, &slot);
	verifyString(result, CUTF16String());
	PA_DisposeUnistring(&result);
	int wow = 99;
	FourDPackex(1, nullptr, &data, &wow);
	check(wow == 0, "non-Windows dispatcher return");
	balanced("scalar content setter survives local destruction");
}

static void deferredArrayCreation()
{
	PA_Variable destination = PA_CreateVariable(eVK_Undefined);
	BytePtr params[] = {reinterpret_cast<BytePtr>(&destination)};
	ARRAY_TEXT source;
	PA_Unichar text[] = {'x', 0};
	source.appendUTF16String(text);
	failHandle = true;
	source.toParamAtIndex(params, 1);
	check(destination.fType == eVK_Undefined,
		  "DEFERRED: initial array creation publishes success-shaped null descriptor");
}

int main(int argc, char **argv)
{
	check(argc >= 2, "test name required");
	gCall4D = host;
	nullEmpty = argc > 2 && std::string(argv[2]) == "null";
	std::string name = argv[1];
	if(name == "arrays") arrays();
	else if(name == "scalars") scalars();
	else if(name == "deferred-array-create") deferredArrayCreation();
	else pictureCase(name);
	std::printf("PASS %s (%s empty)\n", argv[1], nullEmpty ? "null" : "allocated");
}
