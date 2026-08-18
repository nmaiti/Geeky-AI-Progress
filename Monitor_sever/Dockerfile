FROM golang:1.25-alpine AS builder

RUN apk add --no-cache git

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /monitor-server .

FROM alpine:3.20

COPY --from=builder /monitor-server /usr/local/bin/monitor-server

EXPOSE 5000
ENTRYPOINT ["/usr/local/bin/monitor-server"]
