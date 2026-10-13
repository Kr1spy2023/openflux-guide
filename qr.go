//Генератор QR для ссылок

package main

import (
	"fmt"
	"os"

	"github.com/skip2/go-qrcode"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Использование: openflux-guide-qr <текст_или_ссылка>")
		os.Exit(1)
	}

	text := os.Args[1]

	// Medium дает оптимальный баланс избыточности и размера
	q, err := qrcode.New(text, qrcode.Medium)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Ошибка генерации QR-кода: %v\n", err)
		os.Exit(1)
	}

	// Передаем false, чтобы получить черные модули на белом/прозрачном фоне
	fmt.Println(q.ToSmallString(false))
}
