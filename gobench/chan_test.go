package bench

import (
	"fmt"
	"reflect"
	"testing"
)

const oneMillion = 1000000

func BenchmarkCreate(b *testing.B) {
	sizes := []int{0, 1, 2, 3, 4, 5}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("with buffer size %d", size), func(b *testing.B) {
			for i := 0; i < oneMillion; i++ {
				_ = make(chan int, size)
			}
		})
	}
}

func BenchmarkSendRecv(b *testing.B) {
	sizes := []int{0, 1, 2, 3, 4, 5}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("with buffer size %d", size), func(b *testing.B) {
			ch := make(chan int, size)

			go func() {
				for i := 0; i < oneMillion; i++ {
					ch <- 1
				}
			}()

			for i := 0; i < oneMillion; i++ {
				<-ch
			}
		})
	}
}

func BenchmarkSendRecvZeroWidth(b *testing.B) {
	sizes := []int{0, 1, 2, 3, 4, 5}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("with buffer size %d", size), func(b *testing.B) {
			ch := make(chan struct{}, size)

			go func() {
				for i := 0; i < oneMillion; i++ {
					ch <- struct{}{}
				}
			}()

			for i := 0; i < oneMillion; i++ {
				<-ch
			}
		})
	}
}

func BenchmarkSendRecvDynamic(b *testing.B) {
	sizes := []int{0, 1, 2, 3, 4, 5}

	for _, size := range sizes {
		ch := make(chan int, size)
		casesSend := []reflect.SelectCase{reflect.SelectCase{Dir: reflect.SelectSend, Chan: reflect.ValueOf(ch), Send: reflect.ValueOf(0)}}
		casesRecv := []reflect.SelectCase{reflect.SelectCase{Dir: reflect.SelectRecv, Chan: reflect.ValueOf(ch)}}

		b.Run(fmt.Sprintf("with buffer size %d", size), func(b *testing.B) {
			go func() {
				for i := 0; i < oneMillion; i++ {
					_, _, _ = reflect.Select(casesSend)
				}
			}()

			for i := 0; i < oneMillion; i++ {
				_, _, _ = reflect.Select(casesRecv)
			}
		})
	}
}

func BenchmarkMultiCase(b *testing.B) {
	sizes := []int{0, 1, 2, 3, 4, 5}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("with buffer size %d", size), func(b *testing.B) {
			ch1 := make(chan int, size)
			ch2 := make(chan int, size)

			go func() {
				for i := 0; i < oneMillion; i++ {
					select {
					case ch1 <- 0:
					case ch2 <- 0:
					}
				}
			}()

			for i := 0; i < oneMillion; i++ {
				select {
				case <-ch1:
				case <-ch2:
				}
			}
		})
	}
}

func BenchmarkMultiCaseZeroWidth(b *testing.B) {
	sizes := []int{0, 1, 2, 3, 4, 5}
	for _, size := range sizes {
		b.Run(fmt.Sprintf("with buffer size %d", size), func(b *testing.B) {
			ch1 := make(chan struct{}, size)
			ch2 := make(chan struct{}, size)

			go func() {
				for i := 0; i < oneMillion; i++ {
					select {
					case ch1 <- struct{}{}:
					case ch2 <- struct{}{}:
					}
				}
			}()

			for i := 0; i < oneMillion; i++ {
				select {
				case <-ch1:
				case <-ch2:
				}
			}
		})
	}
}
