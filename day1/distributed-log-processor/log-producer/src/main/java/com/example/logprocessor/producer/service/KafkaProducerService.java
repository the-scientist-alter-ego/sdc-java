package com.example.logprocessor.producer.service;

import com.example.logprocessor.producer.model.LogEvent;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Service;

import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

@Service
public class KafkaProducerService {

    private static final Logger logger = LoggerFactory.getLogger(KafkaProducerService.class);

    @Autowired
    private KafkaTemplate<String, String> kafkaTemplate;

    @Autowired
    private ObjectMapper objectMapper;

    @Value("${app.kafka.topic.log-events}")
    private String logEventsTopic;

    public void sendLogEvent(LogEvent logEvent) {
        final String message;
        try {
            message = objectMapper.writeValueAsString(logEvent);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize log event", e);
        }

        try {
            SendResult<String, String> result = kafkaTemplate
                    .send(logEventsTopic, logEvent.getOrganizationId(), message)
                    .get(10, TimeUnit.SECONDS);

            logger.debug("Sent log event: {} to partition: {}",
                    logEvent.getId(), result.getRecordMetadata().partition());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("Interrupted while sending log event", e);
        } catch (ExecutionException | TimeoutException e) {
            logger.error("Failed to send log event: {}", logEvent.getId(), e);
            throw new RuntimeException("Kafka did not acknowledge log event", e);
        }
    }
}
