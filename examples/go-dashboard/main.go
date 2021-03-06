package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"

	"ui"
)

var (
	WarningLogger *log.Logger
	InfoLogger    *log.Logger
	ErrorLogger   *log.Logger

	NETWORK_BUFFER_MAX_SIZE uint16 = 12288
	NETWORK_BUFFER_LENGTH_DIGITS uint16 = 5
)

type packet_event struct {
	ThreadID uint8  `json:"thread_id"`
	PacketID uint64 `json:"packet_id"`

	FlowID       uint32 `json:"flow_id"`
	FlowPacketID uint64 `json:"flow_packet_id"`

	PacketEventID       uint8  `json:"packet_event_id"`
	PacketEventName     string `json:"packet_event_name"`
	PacketOversize      bool   `json:"pkt_oversize"`
	PacketTimestampS    uint64 `json:"pkt_ts_sec"`
	PacketTimestampUs   uint64 `json:"pkt_ts_usec"`
	PacketLength        uint32 `json:"pkt_len"`
	PacketL4Length      uint32 `json:"pkt_l4_len"`
	Packet              string `json:"pkt"`
	PacketCaptureLength uint32 `json:"pkt_caplen"`
	PacketType          uint32 `json:"pkt_type"`
	PacketL3Offset      uint32 `json:"pkt_l3_offset"`
	PacketL4Offset      uint32 `json:"pkt_l4_offset"`
}

type flow_event struct {
	ThreadID uint8  `json:"thread_id"`
	PacketID uint64 `json:"packet_id"`

	FlowID                    uint32 `json:"flow_id"`
	FlowPacketID              uint64 `json:"flow_packet_id"`
	FlowFirstSeen             uint64 `json:"flow_first_seen"`
	FlowLastSeen              uint64 `json:"flow_last_seen"`
	FlowTotalLayer4DataLength uint64 `json:"flow_tot_l4_data_len"`
	FlowMinLayer4DataLength   uint64 `json:"flow_min_l4_data_len"`
	FlowMaxLayer4DataLength   uint64 `json:"flow_max_l4_data_len"`
	FlowAvgLayer4DataLength   uint64 `json:"flow_avg_l4_data_len"`
	FlowDatalinkLayer         uint8  `json:"flow_datalink"`
	MaxPackets                uint8  `json:"flow_max_packets"`
	IsMidstreamFlow           uint32 `json:"midstream"`
}

type basic_event struct {
	ThreadID uint8  `json:"thread_id"`
	PacketID uint64 `json:"packet_id"`

	BasicEventID   uint8  `json:"basic_event_id"`
	BasicEventName string `json:"basic_event_name"`
}

func processJson(jsonStr string) {
	jsonMap := make(map[string]interface{})
	err := json.Unmarshal([]byte(jsonStr), &jsonMap)
	if err != nil {
		ErrorLogger.Printf("BUG: JSON error: %v\n", err)
		os.Exit(1)
	}
	if jsonMap["packet_event_id"] != nil {
		pe := packet_event{}
		if err := json.Unmarshal([]byte(jsonStr), &pe); err != nil {
			ErrorLogger.Printf("BUG: JSON Unmarshal error: %v\n", err)
			os.Exit(1)
		}
		InfoLogger.Printf("PACKET EVENT %v\n", pe)
	} else if jsonMap["flow_event_id"] != nil {
		fe := flow_event{}
		if err := json.Unmarshal([]byte(jsonStr), &fe); err != nil {
			ErrorLogger.Printf("BUG: JSON Unmarshal error: %v\n", err)
			os.Exit(1)
		}
		InfoLogger.Printf("FLOW EVENT %v\n", fe)
	} else if jsonMap["basic_event_id"] != nil {
		be := basic_event{}
		if err := json.Unmarshal([]byte(jsonStr), &be); err != nil {
			ErrorLogger.Printf("BUG: JSON Unmarshal error: %v\n", err)
			os.Exit(1)
		}
		InfoLogger.Printf("BASIC EVENT %v\n", be)
	} else {
		ErrorLogger.Printf("BUG: Unknown JSON: %v\n", jsonStr)
		os.Exit(1)
	}
	//InfoLogger.Printf("JSON map: %v\n-------------------------------------------------------\n", jsonMap)
}

func eventHandler(ui *ui.Tui, wdgts *ui.Widgets, reader chan string) {
	for {
		select {
		case <-ui.MainTicker.C:
			if err := wdgts.RawJson.Write(fmt.Sprintf("%s\n", "--- HEARTBEAT ---")); err != nil {
				panic(err)
			}

		case <-ui.Context.Done():
			return

		case jsonStr := <-reader:
			if err := wdgts.RawJson.Write(fmt.Sprintf("%s\n", jsonStr)); err != nil {
				panic(err)
			}
		}
	}
}

func main() {
	InfoLogger = log.New(os.Stderr, "INFO: ", log.Ldate|log.Ltime|log.Lshortfile)
	WarningLogger = log.New(os.Stderr, "WARNING: ", log.Ldate|log.Ltime|log.Lshortfile)
	ErrorLogger = log.New(os.Stderr, "ERROR: ", log.Ldate|log.Ltime|log.Lshortfile)

	writer := make(chan string, 256)

	go func(writer chan string) {
		con, err := net.Dial("tcp", "127.0.0.1:7000")
		if err != nil {
			ErrorLogger.Printf("Connection failed: %v\n", err)
			os.Exit(1)
		}

		buf := make([]byte, NETWORK_BUFFER_MAX_SIZE)
		jsonStr := string("")
		jsonStrLen := uint16(0)
		jsonLen := uint16(0)
		brd := bufio.NewReaderSize(con, int(NETWORK_BUFFER_MAX_SIZE))

		for {
			nread, err := brd.Read(buf)

			if err != nil {
				if err != io.EOF {
					ErrorLogger.Printf("Read Error: %v\n", err)
					break
				}
			}

			if nread == 0 || err == io.EOF {
				WarningLogger.Printf("Disconnect from Server\n")
				break
			}

			jsonStr += string(buf[:nread])
			jsonStrLen += uint16(nread)

			for {
				if jsonStrLen < NETWORK_BUFFER_LENGTH_DIGITS+1 {
					break
				}

				if jsonStr[NETWORK_BUFFER_LENGTH_DIGITS] != '{' {
					ErrorLogger.Printf("BUG: JSON invalid opening character at position %d: '%s' (%x)\n",
						NETWORK_BUFFER_LENGTH_DIGITS,
						string(jsonStr[:NETWORK_BUFFER_LENGTH_DIGITS]), jsonStr[NETWORK_BUFFER_LENGTH_DIGITS])
					os.Exit(1)
				}

				if jsonLen == 0 {
					var tmp uint64
					if tmp, err = strconv.ParseUint(strings.TrimLeft(jsonStr[:NETWORK_BUFFER_LENGTH_DIGITS], "0"), 10, 16); err != nil {
						ErrorLogger.Printf("BUG: Could not parse length of a JSON string: %v\n", err)
						os.Exit(1)
					} else {
						jsonLen = uint16(tmp)
					}
				}

				if jsonStrLen < jsonLen+NETWORK_BUFFER_LENGTH_DIGITS {
					break
				}

				if jsonStr[jsonLen+NETWORK_BUFFER_LENGTH_DIGITS-2] != '}' || jsonStr[jsonLen+NETWORK_BUFFER_LENGTH_DIGITS-1] != '\n' {
					ErrorLogger.Printf("BUG: JSON invalid closing character at position %d: '%s'\n",
						jsonLen+NETWORK_BUFFER_LENGTH_DIGITS,
						string(jsonStr[jsonLen+NETWORK_BUFFER_LENGTH_DIGITS-1]))
					os.Exit(1)
				}

				writer <- jsonStr[NETWORK_BUFFER_LENGTH_DIGITS : NETWORK_BUFFER_LENGTH_DIGITS+jsonLen]

				jsonStr = jsonStr[jsonLen+NETWORK_BUFFER_LENGTH_DIGITS:]
				jsonStrLen -= (jsonLen + NETWORK_BUFFER_LENGTH_DIGITS)
				jsonLen = 0
			}
		}
	}(writer)

	tui, wdgts := ui.Init()
	go eventHandler(tui, wdgts, writer)
	ui.Run(tui)

/*
    for {
        select {
        case _ = <-writer:
            break
        }
    }
*/
}
