import hashlib
import os

from dotenv import load_dotenv
load_dotenv()

def makeUID(filePath: str, fileName: str):
    string = filePath+fileName
    return hashlib.sha256(string.encode()).hexdigest()[:20]

def makeLink(UID: str):
    #Reverse the string
    reverseUID = UID[::-1]

    #Convert to list for mutation
    reverseUID = list(reverseUID)

    #54321 --> 45231 scrambling 
    for i in range(0, len(reverseUID) - 1, 2):
        reverseUID[i], reverseUID[i + 1] = reverseUID[i + 1], reverseUID[i]
    scrambled = "".join(reverseUID)
    
    #Final Link
    link = str(os.getenv("SHARING_ENDPOINT"))+scrambled+".file"
    return link

def decodeLink(link: str):
    link = list(link)

    #Remove fillers
    indices = [len(str(os.getenv("SHARING_ENDPOINT"))), len(".file")]
    scrambled = link[indices[0] : -indices[1]]

    #Unscrambling
    for i in range(0, len(scrambled) - 1, 2):
        scrambled[i], scrambled[i+1] = scrambled[i+1], scrambled[i]
    reverseUID = "".join(scrambled)

    #Re-reversing
    UID = reverseUID[::-1]
    return UID

    