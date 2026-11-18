// Package eventstream publishes the events of lumen-api to Kafka and consumes
// them (issue #44, docs/runbooks/kafka.md).
//
//	events ── trigger ──> outbox ── Relay ──> topic ── Consumer ──> event_counts
//
// Delivery is at least once: the relay can publish an event again after a
// crash, and the consumer applies each event id once.
package eventstream

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/twmb/franz-go/pkg/kgo"
)

// Config of the relay and the consumer, read from the environment.
type Config struct {
	PostgresDSN     string
	Brokers         []string
	Topic           string
	DeadLetterTopic string
	Group           string
	// CAFile is the cluster CA, CertFile and KeyFile the client certificate
	// (Secret of the KafkaUser). Without CAFile the connection is in clear,
	// for tests.
	CAFile   string
	CertFile string
	KeyFile  string
	// AdminAddr serves /metrics and /livez
	AdminAddr string
}

// ConfigFromEnv reads the configuration.
func ConfigFromEnv() (Config, error) {
	c := Config{
		PostgresDSN:     os.Getenv("PG_DSN"),
		Topic:           envOr("KAFKA_TOPIC", "lumen.events"),
		DeadLetterTopic: envOr("KAFKA_DEAD_LETTER_TOPIC", "lumen.events.dlq"),
		Group:           envOr("KAFKA_GROUP", "lumen-events-consumer"),
		CAFile:          os.Getenv("KAFKA_CA_FILE"),
		CertFile:        os.Getenv("KAFKA_CERT_FILE"),
		KeyFile:         os.Getenv("KAFKA_KEY_FILE"),
		AdminAddr:       ":" + envOr("ADMIN_PORT", "9090"),
	}
	if b := os.Getenv("KAFKA_BROKERS"); b != "" {
		c.Brokers = strings.Split(b, ",")
	}
	if c.PostgresDSN == "" {
		return c, errors.New("PG_DSN is not set")
	}
	if len(c.Brokers) == 0 {
		return c, errors.New("KAFKA_BROKERS is not set")
	}
	return c, nil
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// clientOptions returns the connection options of a Kafka client.
func (c Config) clientOptions() ([]kgo.Opt, error) {
	opts := []kgo.Opt{kgo.SeedBrokers(c.Brokers...)}
	if c.CAFile == "" {
		return opts, nil
	}
	tlsConfig, err := c.tlsConfig()
	if err != nil {
		return nil, err
	}
	return append(opts, kgo.DialTLSConfig(tlsConfig)), nil
}

// tlsConfig reads the client certificate at each handshake: the User Operator
// renews it in the mounted Secret, and a running client picks it up.
func (c Config) tlsConfig() (*tls.Config, error) {
	ca, err := os.ReadFile(c.CAFile)
	if err != nil {
		return nil, fmt.Errorf("kafka CA: %w", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return nil, fmt.Errorf("kafka CA: no certificate in %s", c.CAFile)
	}
	if _, err := tls.LoadX509KeyPair(c.CertFile, c.KeyFile); err != nil {
		return nil, fmt.Errorf("kafka client certificate: %w", err)
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
		GetClientCertificate: func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
			cert, err := tls.LoadX509KeyPair(c.CertFile, c.KeyFile)
			if err != nil {
				return nil, fmt.Errorf("kafka client certificate: %w", err)
			}
			return &cert, nil
		},
	}, nil
}
