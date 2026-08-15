import express from "express";

import { logger } from "../lib/logger";
import { normalizeSMSPhoneNumber, setSMSOptOut } from "../services/sms/SMSOptOutStore";

const STOP_KEYWORDS = new Set(["STOP", "STOPALL", "UNSUBSCRIBE", "CANCEL", "END", "QUIT"]);
const START_KEYWORDS = new Set(["START", "UNSTOP", "YES"]);
const HELP_KEYWORDS = new Set(["HELP", "INFO"]);

function firstToken(value: unknown): string {
  return typeof value === "string" ? value.trim().split(/\s+/)[0]?.toUpperCase() ?? "" : "";
}

function stringField(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function twiml(message?: string): string {
  const escaped = (message ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&apos;");
  return message
    ? `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${escaped}</Message></Response>`
    : `<?xml version="1.0" encoding="UTF-8"?><Response></Response>`;
}

function redactedPhone(value: string): string {
  const normalized = normalizeSMSPhoneNumber(value);
  return normalized ? `...${normalized.slice(-4)}` : "";
}

export function twilioRouter(): express.Router {
  const router = express.Router();

  router.post("/inbound-sms", async (req, res) => {
    const from = stringField(req.body.From);
    const to = stringField(req.body.To);
    const body = stringField(req.body.Body);
    const messageSid = stringField(req.body.MessageSid);
    const keyword = firstToken(body);

    try {
      if (STOP_KEYWORDS.has(keyword)) {
        await setSMSOptOut(from, true, keyword, "twilio");
        logger.info({ messageSid, from: redactedPhone(from), to: redactedPhone(to), keyword }, "[twilio] inbound STOP");
        res.type("text/xml").status(200).send(twiml("You have been unsubscribed from OneWay SMS messages. You will no longer receive SMS from this number. Reply START to resubscribe."));
        return;
      }

      if (START_KEYWORDS.has(keyword)) {
        await setSMSOptOut(from, false, keyword, "twilio");
        logger.info({ messageSid, from: redactedPhone(from), to: redactedPhone(to), keyword }, "[twilio] inbound START");
        res.type("text/xml").status(200).send(twiml("You have resubscribed to OneWay SMS messages. Reply STOP to opt out or HELP for help."));
        return;
      }

      if (HELP_KEYWORDS.has(keyword)) {
        logger.info({ messageSid, from: redactedPhone(from), to: redactedPhone(to), keyword }, "[twilio] inbound HELP");
        res.type("text/xml").status(200).send(twiml("OneWay help: Visit https://oneway.is/support or email support@oneway.is. Reply STOP to opt out."));
        return;
      }

      logger.info({ messageSid, from: redactedPhone(from), to: redactedPhone(to), keyword }, "[twilio] inbound SMS received");
      res.type("text/xml").status(200).send(twiml());
    } catch (error) {
      logger.error({ error, messageSid, from: redactedPhone(from), to: redactedPhone(to), keyword }, "[twilio] inbound SMS failed");
      res.type("text/xml").status(200).send(twiml("OneWay could not process that message yet. Visit https://oneway.is/support or email support@oneway.is for help."));
    }
  });

  router.post("/message-status", (req, res) => {
    const messageSid = stringField(req.body.MessageSid);
    const messageStatus = stringField(req.body.MessageStatus);
    const errorCode = stringField(req.body.ErrorCode);
    const errorMessage = stringField(req.body.ErrorMessage);
    const logPayload = {
      messageSid,
      messageStatus,
      errorCode: errorCode || undefined,
      errorMessage: errorMessage || undefined,
      to: redactedPhone(stringField(req.body.To)),
      from: redactedPhone(stringField(req.body.From)),
    };

    if (errorCode || ["failed", "undelivered"].includes(messageStatus.toLowerCase())) {
      logger.warn(logPayload, "[twilio] message status failure");
    } else {
      logger.info(logPayload, "[twilio] message status");
    }

    res.status(204).end();
  });

  return router;
}
