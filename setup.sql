-- =============================================================================
-- CYBER DEMO SETUP SCRIPT
-- Federal Cyber Incident Intelligence — Snowflake Dynamic Tables + Cortex Demo
-- =============================================================================
-- Run this entire script in a Snowsight worksheet using ACCOUNTADMIN (or any
-- role that can CREATE DATABASE, CREATE WAREHOUSE, and CREATE ROLE).
--
-- SECTIONS:
--   1. Role, Warehouse, Database, Schema
--   2. Cortex & AI function grants
--   3. Grant role to your user  ← replace <YOUR_USER>
--   4. Base table DDL
--   5. 500 rows of synthetic incident data
--   6. Dynamic Table (CYBER_INCIDENTS_SUMMARY)
--   7. Verification queries
-- =============================================================================


-- =============================================================================
-- SECTION 1: ROLE, WAREHOUSE, DATABASE, SCHEMA
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS STREAMLIT_DEMO_ROLE
    COMMENT = 'Role for the Federal Cyber Incident Intelligence Streamlit demo';

CREATE WAREHOUSE IF NOT EXISTS DEMO_WH
    WAREHOUSE_SIZE   = 'XSMALL'
    AUTO_SUSPEND     = 60
    AUTO_RESUME      = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'XS warehouse for the Streamlit demo; auto-suspends after 60s of inactivity';

CREATE DATABASE IF NOT EXISTS CYBER_DEMO
    COMMENT = 'Database for the Federal Cyber Incident Intelligence demo';

CREATE SCHEMA IF NOT EXISTS CYBER_DEMO.PUBLIC;

-- Warehouse access
GRANT USAGE ON WAREHOUSE DEMO_WH TO ROLE STREAMLIT_DEMO_ROLE;

-- Database + schema access
GRANT USAGE  ON DATABASE CYBER_DEMO          TO ROLE STREAMLIT_DEMO_ROLE;
GRANT USAGE  ON SCHEMA   CYBER_DEMO.PUBLIC   TO ROLE STREAMLIT_DEMO_ROLE;
GRANT CREATE TABLE ON SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE;
GRANT CREATE DYNAMIC TABLE ON SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE;

-- Object-level grants (cover tables created below)
GRANT SELECT, INSERT ON ALL TABLES    IN SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE;
GRANT SELECT, INSERT ON FUTURE TABLES IN SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES    IN SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE;


-- =============================================================================
-- SECTION 2: CORTEX & AI FUNCTION GRANTS
-- =============================================================================
-- SNOWFLAKE.CORTEX_USER     — grants access to CORTEX.COMPLETE, CORTEX.SENTIMENT, etc.
-- SNOWFLAKE.AI_FUNCTIONS_USER — broader AI function access (belt-and-suspenders)

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER        TO ROLE STREAMLIT_DEMO_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.AI_FUNCTIONS_USER  TO ROLE STREAMLIT_DEMO_ROLE;


-- =============================================================================
-- SECTION 3: GRANT ROLE TO YOUR USER
-- =============================================================================
-- Replace <YOUR_USER> with your Snowflake login name (e.g. JSMITH or jsmith@agency.gov)

GRANT ROLE STREAMLIT_DEMO_ROLE TO USER KPBONG;


-- =============================================================================
-- SECTION 4: BASE TABLE DDL
-- =============================================================================

USE ROLE     STREAMLIT_DEMO_ROLE;
USE WAREHOUSE DEMO_WH;
USE DATABASE  CYBER_DEMO;
USE SCHEMA    PUBLIC;

CREATE TABLE IF NOT EXISTS CYBER_INCIDENTS_RAW (
    incident_id      VARCHAR(20)   NOT NULL COMMENT 'Unique incident identifier, e.g. INC-2026-00001',
    agency           VARCHAR(50)   NOT NULL COMMENT 'Federal agency that reported the incident',
    severity         VARCHAR(20)   NOT NULL COMMENT 'Low | Medium | High | Critical',
    incident_type    VARCHAR(50)   NOT NULL COMMENT 'Classification of the incident vector',
    detected_at      TIMESTAMP_NTZ NOT NULL COMMENT 'Timestamp when the incident was first detected',
    affected_systems INTEGER       NOT NULL COMMENT 'Number of systems affected at time of detection',
    status           VARCHAR(20)   NOT NULL COMMENT 'Open | Contained | Resolved',
    narrative        TEXT          NOT NULL COMMENT 'Free-text analyst description of the incident'
);


-- =============================================================================
-- SECTION 5: SYNTHETIC DATA — 500 ROWS
-- =============================================================================
-- Distribution design:
--   Severity : ~10% Critical, ~20% High, ~40% Medium, ~30% Low
--   Agencies : CISA and DOD heaviest (realistic — they handle most incidents)
--   Types    : Phishing > Ransomware > Credential Theft > others
--   Status   : ~30% Open, ~30% Contained, ~40% Resolved
--   Dates    : random spread across the past 90 days
--
-- Narratives: 4 distinct variants per incident type (32 unique narratives total)
--   selected by (row_number % 4) so no two consecutive rows are identical.
-- =============================================================================

INSERT INTO CYBER_INCIDENTS_RAW (
    incident_id, agency, severity, incident_type,
    detected_at, affected_systems, status, narrative
)
WITH base AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY SEQ4())     AS rn,
        UNIFORM(1, 100, RANDOM(42))             AS sev_rand,
        UNIFORM(1, 100, RANDOM(17))             AS agency_rand,
        UNIFORM(1, 100, RANDOM(99))             AS type_rand,
        UNIFORM(1, 100, RANDOM(7))              AS status_rand,
        UNIFORM(1, 500, RANDOM(53))             AS affected_sys,
        DATEADD('minute',
            -UNIFORM(1, 129600, RANDOM(31)),    -- up to 90 days ago
            CURRENT_TIMESTAMP()
        )                                       AS detected_at
    FROM TABLE(GENERATOR(ROWCOUNT => 500))
),
classified AS (
    SELECT
        rn,
        detected_at,
        affected_sys,

        -- Severity: weighted toward Medium/Low
        CASE
            WHEN sev_rand <=  10 THEN 'Critical'
            WHEN sev_rand <=  30 THEN 'High'
            WHEN sev_rand <=  70 THEN 'Medium'
            ELSE                      'Low'
        END AS severity,

        -- Agency: CISA and DOD handle the most incidents
        CASE
            WHEN agency_rand <=  16 THEN 'CISA'
            WHEN agency_rand <=  30 THEN 'DOD'
            WHEN agency_rand <=  42 THEN 'DHS'
            WHEN agency_rand <=  52 THEN 'Treasury'
            WHEN agency_rand <=  62 THEN 'State'
            WHEN agency_rand <=  70 THEN 'HHS'
            WHEN agency_rand <=  78 THEN 'VA'
            WHEN agency_rand <=  85 THEN 'DOE'
            WHEN agency_rand <=  92 THEN 'NASA'
            ELSE                         'FBI'
        END AS agency,

        -- Type: Phishing most common, Zero-Day rarest
        CASE
            WHEN type_rand <=  22 THEN 'Phishing'
            WHEN type_rand <=  38 THEN 'Ransomware'
            WHEN type_rand <=  53 THEN 'Credential Theft'
            WHEN type_rand <=  65 THEN 'Insider Threat'
            WHEN type_rand <=  76 THEN 'Supply Chain'
            WHEN type_rand <=  86 THEN 'DDoS'
            WHEN type_rand <=  93 THEN 'Misconfiguration'
            ELSE                        'Zero-Day Exploit'
        END AS incident_type,

        -- Status: slight lean toward Resolved (older incidents get closed)
        CASE
            WHEN status_rand <=  30 THEN 'Open'
            WHEN status_rand <=  60 THEN 'Contained'
            ELSE                         'Resolved'
        END AS status

    FROM base
)
SELECT
    'INC-2026-' || LPAD(rn::VARCHAR, 5, '0') AS incident_id,
    agency,
    severity,
    incident_type,
    detected_at,
    affected_sys AS affected_systems,
    status,

    -- -------------------------------------------------------------------------
    -- NARRATIVE — 4 distinct variants per incident_type, cycled by (rn % 4)
    -- Each variant is 2-4 sentences grounded in realistic federal IR language.
    -- -------------------------------------------------------------------------
    CASE incident_type

        WHEN 'Phishing' THEN CASE (rn % 4)
            WHEN 0 THEN 'A targeted spear-phishing campaign was identified against senior officials using spoofed .gov domains designed to harvest VPN and email credentials. The attacker compromised three executive accounts before the security operations center detected anomalous login activity from overseas IP addresses. Email gateway logs indicate the campaign originated from infrastructure previously attributed to a nation-state threat actor.'
            WHEN 1 THEN 'Analysts detected a phishing wave that exploited a recent legislative announcement as a social engineering lure, with malicious links embedded in PDF attachments sent to procurement staff across four offices. The security operations center quarantined 47 mailboxes within two hours of the initial detection alert. Supplementary indicators suggest the threat actor had prior knowledge of internal distribution lists, pointing to a possible earlier access.'
            WHEN 2 THEN 'An adversary conducted a voice-phishing campaign against help desk personnel to reset multi-factor authentication tokens, successfully bypassing two-factor controls for a privileged service account. Network telemetry showed lateral movement attempts within 12 minutes of the credential compromise, targeting file servers hosting sensitive budget data. The account was suspended and all affected systems were immediately isolated for forensic imaging.'
            ELSE         'A large-scale phishing kit was discovered replicating the agency internal portal login page pixel-for-pixel, with threat intelligence linking the hosting infrastructure to a financially motivated criminal group with a history of targeting federal contractors. Over 200 employees received the malicious emails before the campaign was blocked at the secure email gateway. User awareness training was accelerated agency-wide and additional detection signatures were deployed to all mail filters.'
        END

        WHEN 'Ransomware' THEN CASE (rn % 4)
            WHEN 0 THEN 'Ransomware was deployed across a primary file share server after an initial access broker sold stolen VPN credentials harvested in a prior phishing campaign. Encryption began at 0200 local time and spread to 14 adjacent systems before automated network segmentation halted propagation. Backups were confirmed intact and full restoration proceeded under the agency incident response protocol within 18 hours.'
            WHEN 1 THEN 'A ransomware variant consistent with the ALPHV BlackCat family was identified encrypting mission-critical databases after the threat actor maintained undetected persistence for an estimated 18 days. The attacker demanded payment in cryptocurrency and threatened to publish exfiltrated personnel records on a dark web leak site. CISA was notified and a joint incident response team comprising agency personnel and external forensics specialists was activated within the hour.'
            WHEN 2 THEN 'Ransomware execution was halted by endpoint detection and response tooling after encrypting files on a single financial analyst workstation, preventing broader network propagation. Forensic analysis identified the infection vector as a trojanized software update delivered through a third-party budget management platform used across the agency. The incident was escalated to critical priority due to the supply-chain implications and the vendor was notified for urgent investigation.'
            ELSE         'A ransomware note was discovered on a shared network drive following an overnight maintenance window, with investigation determining the attacker had maintained persistent access for 23 days before deploying the final payload. All 38 affected hosts were isolated within two hours and rebuilt from known-good images maintained in a segregated backup environment. Post-incident review identified a gap in privileged access monitoring on legacy servers that enabled the extended dwell time.'
        END

        WHEN 'Credential Theft' THEN CASE (rn % 4)
            WHEN 0 THEN 'An adversary used a Pass-the-Hash technique to escalate privileges after successfully dumping LSASS memory on a workstation belonging to a systems administrator with broad domain access. The compromised account had read permissions on classified project repositories and sensitive inter-agency acquisition communications. Incident response involved emergency rotation of all domain credentials, a privileged access audit, and deployment of additional endpoint monitoring.'
            WHEN 1 THEN 'Credential harvesting malware was discovered on a contractor-issued laptop after behavioral analytics flagged anomalous LDAP enumeration queries originating from the device outside normal business hours. By the time of detection, the attacker had exfiltrated a partial Active Directory database dump containing password hashes for over 300 accounts. All contractor access was immediately revoked, affected accounts were locked, and a full forensic investigation was initiated under IR protocol.'
            WHEN 2 THEN 'A service account password appeared in a dark web credential dump linked to a breach at a third-party SaaS provider, triggering an automated alert when a login attempt was made from an IP address geolocated to a country of concern. The account was locked within four minutes of the alert and a forensic review of all access activity for the preceding 30 days was completed within two hours. Enhanced monitoring and stricter rotation policies were applied to all remaining service accounts as a precautionary measure.'
            ELSE         'OAuth tokens for a cloud-based collaboration platform were stolen via a man-in-the-middle attack conducted on an unsecured conference facility network during an interagency summit. The tokens granted the attacker read access to sensitive inter-agency communications and shared documents spanning a 90-day window. All active sessions were globally invalidated within the hour and hardware-backed authentication was enforced for all platform users as an immediate corrective control.'
        END

        WHEN 'Insider Threat' THEN CASE (rn % 4)
            WHEN 0 THEN 'A database administrator was found to have exfiltrated sensitive procurement records to a personal cloud storage account over a two-month period using an automated synchronization script installed on a government workstation. Behavioral analytics flagging high-volume after-hours file downloads triggered the initial alert that led to the discovery. The employee was placed on administrative leave pending a full Office of Inspector General investigation and potential referral for criminal prosecution.'
            WHEN 1 THEN 'An analyst with elevated system privileges accessed classified personnel files outside their authorized scope for 11 consecutive days before the anomaly was surfaced by data loss prevention monitoring. Movement of approximately 4,000 files to a removable USB device was captured in access logs that had not been reviewed due to an alerting configuration gap discovered during the investigation. Credentials were revoked immediately and a counterintelligence referral was made to the appropriate federal law enforcement authority.'
            WHEN 2 THEN 'A departing employee attempted to bulk-download source code repositories stored in a classified development environment on their final day of employment, which was blocked in real time by data loss prevention controls. A subsequent forensic review revealed that a subset of the same code base had been emailed to a personal account in small batches over the preceding four weeks, circumventing automated controls. Legal counsel and HR were notified and the incident has been referred for potential prosecution under 18 U.S.C. 1832.'
            ELSE         'Security operations identified a network engineer who had installed unauthorized remote access software on core routing infrastructure serving a classified enclave, providing persistent external access that bypassed standard multi-factor authentication controls. The engineer claimed the tool was installed for personal convenience to support after-hours troubleshooting, but review of access logs revealed sessions during periods with no open change tickets. The matter was referred to the OIG given the sensitivity of the affected infrastructure and the potential for undetected data access.'
        END

        WHEN 'Supply Chain' THEN CASE (rn % 4)
            WHEN 0 THEN 'A widely deployed network monitoring appliance was found to contain a hardware backdoor introduced during the manufacturing process, enabling covert encrypted command-and-control communications to external infrastructure. The appliance had been deployed across 12 agency locations over 18 months and had passed standard receiving inspection without detection. All affected units were immediately isolated, the vendor was formally notified, and replacement hardware was sourced through an accredited alternate supply chain.'
            WHEN 1 THEN 'A software update from a trusted governance and compliance platform vendor contained a malicious payload that established encrypted command-and-control communications with adversary-controlled infrastructure upon installation. The update had passed standard vulnerability scanning and code-signing certificate verification before being deployed to 200 agency workstations through the automated patching pipeline. The incident revealed a critical gap in behavioral analysis of third-party software following installation and prompted an immediate review of all recent updates from the same vendor.'
            WHEN 2 THEN 'A third-party IT services firm responsible for agency help desk operations was itself compromised in a separate incident, exposing support credentials used to access the agency internal ticketing and remote desktop systems. Attackers leveraged this trusted third-party access to create new privileged accounts that persisted for 15 days before detection through anomalous account creation alerts. A full audit of all third-party managed systems, accounts, and recent change activity is underway with enhanced monitoring applied to all vendor-managed endpoints.'
            ELSE         'Outbound network traffic analysis revealed that a commercially available productivity application was silently exfiltrating detailed system telemetry and document metadata to servers hosted in a jurisdiction of concern, without disclosure in the terms of service or the approved software documentation. The vendor denied knowledge of the behavior and attributed it to a compromised build pipeline at a contracted software component supplier. The application was removed from all 3,400 agency endpoints within 24 hours pending a formal Foreign Ownership Control and Influence review and replacement evaluation.'
        END

        WHEN 'DDoS' THEN CASE (rn % 4)
            WHEN 0 THEN 'A volumetric distributed denial-of-service attack peaked at 340 gigabits per second, overwhelming the agency external-facing web portal and causing complete service degradation for four and a half hours during peak operational hours. Traffic analysis identified a botnet composed of over 180,000 compromised consumer IoT devices distributed across 40 countries as the primary attack source. Upstream BGP scrubbing services were activated and successfully mitigated the residual attack traffic within the hour, restoring full service availability.'
            WHEN 1 THEN 'An application-layer denial-of-service attack targeted the agency citizen-facing benefits enrollment portal during the peak of an annual open enrollment period, using HTTP/2 rapid-reset techniques to exhaust all available web server connection threads within minutes. The attack reached three million requests per second at peak before the content delivery network DDoS protection profile was fully activated and rate-limiting rules were propagated globally. Service was restored to full capacity within 90 minutes with no data loss or unauthorized system access identified during the incident window.'
            WHEN 2 THEN 'A DNS amplification attack exploiting misconfigured third-party resolvers disrupted external name resolution for agency domains, impacting email delivery, remote access services, and 14 partner API integrations for approximately three hours. The attack was publicly claimed by a hacktivist collective expressing opposition to a recent agency enforcement action and was coordinated with parallel social media pressure campaigns. ISP-level null routing of the amplification sources reduced the attack volume within 90 minutes and full service was restored after DNS cache propagation completed.'
            ELSE         'A coordinated denial-of-service campaign simultaneously targeted three agency sub-domains hosting public-facing grant applications, mission data portals, and contractor self-service tools, in a pattern consistent with prior reconnaissance of the external network architecture. Rate-limiting policies, geographic blocking rules, and JavaScript challenge-response mechanisms were deployed in sequence to progressively reduce the effective attack surface over a two-hour period. Full service restoration was achieved within three hours with no evidence of data exfiltration or unauthorized system access during the outage window.'
        END

        WHEN 'Misconfiguration' THEN CASE (rn % 4)
            WHEN 0 THEN 'A cloud storage bucket containing sensitive inter-agency memoranda and draft policy documents was discovered with public read permissions resulting from a misconfigured IAM policy inadvertently applied during a cloud migration project. The estimated exposure window was 72 hours before the cloud security posture management platform generated the misconfiguration alert. Enhanced CSPM alerting rules and a mandatory peer-review process for all storage permission changes were implemented as immediate corrective actions.'
            WHEN 1 THEN 'An exposed Kubernetes management dashboard with no authentication controls was identified on an agency development environment that had been inadvertently assigned an externally routable IP address during a network configuration change. The dashboard exposed environment variables containing production database connection strings, API keys, and internal service endpoints visible without credentials. The environment was taken offline within 30 minutes of discovery and a comprehensive review of all Kubernetes deployments for similar external exposure was initiated across all agency cloud tenants.'
            WHEN 2 THEN 'A network firewall rule change intended exclusively for an isolated penetration testing environment was accidentally applied to the production perimeter firewall, permitting unrestricted inbound connections on port 22 for approximately six hours before the error was detected during a routine audit. SSH brute-force login attempts from over 200 distinct external addresses were logged continuously throughout the exposure window and are being analyzed for any successful authentication events. The change management process was immediately updated to require dual approval and automated validation checks for all production firewall rule modifications.'
            ELSE         'An administrator misconfigured multi-factor authentication bypass settings on the agency cloud identity provider while processing a bulk exception request from a field office, inadvertently disabling MFA enforcement for an entire department of 85 users for 48 hours before the configuration error was discovered. Three suspicious login attempts from unrecognized device fingerprints and one successful authentication from an unmanaged personal device were detected and investigated during this window. All affected accounts underwent full forensic review, MFA was reinstated using an emergency change process, and the exception workflow was redesigned to prevent bulk changes without security team countersignature.'
        END

        ELSE -- 'Zero-Day Exploit'
            CASE (rn % 4)
            WHEN 0 THEN 'A previously unknown vulnerability in a widely deployed edge VPN appliance was weaponized by a sophisticated threat actor to achieve unauthenticated remote code execution at the network perimeter without requiring valid credentials. The agency received notification from the CISA Known Exploited Vulnerabilities working group 48 hours after limited public disclosure of active exploitation in the wild. Emergency patching of all affected appliances and a comprehensive forensic review of associated network and authentication logs are in progress to determine the full scope of potential access.'
            WHEN 1 THEN 'Exploitation of a zero-day vulnerability in a widely used document rendering library was detected via endpoint detection and response telemetry showing anomalous child process spawning from a PDF viewer application on an analyst workstation. Technical indicators recovered from the malware artifacts are consistent with an advanced persistent threat actor with documented targeting interest in energy sector research and acquisition data. The affected endpoints were quarantined immediately, forensic images were preserved, and samples were submitted to CISA for broader threat intelligence sharing across the federal community.'
            WHEN 2 THEN 'A zero-day vulnerability in the agency federated identity provider was actively exploited to forge signed authentication tokens, enabling the attacker to impersonate privileged users and access sensitive internal resources without valid credentials or MFA prompts. The vulnerability was privately disclosed to the agency by an independent security researcher who simultaneously notified the software vendor and coordinated with CISA for responsible disclosure. A compensating control blocking the vulnerable authentication pathway was implemented within six hours while an emergency out-of-band patch was developed, tested, and deployed across all agency identity provider instances.'
            ELSE         'Security researchers shared technical indicators of compromise suggesting an unpatched zero-day in a widely used containerized workload management platform was being actively exploited across multiple federal agencies as part of a coordinated campaign attributed to a foreign intelligence service. Agency instances were emergency-patched and subjected to comprehensive forensic analysis within 24 hours of receiving the joint advisory from CISA and the vendor. No evidence of successful exploitation was identified within agency environments, but enhanced behavioral monitoring on all container orchestration components and associated network egress traffic remains active pending the vendor issuing formal confirmation of complete remediation.'
        END

    END AS narrative

FROM classified;


-- =============================================================================
-- SECTION 6: DYNAMIC TABLE — CYBER_INCIDENTS_SUMMARY
-- =============================================================================
-- Target lag: 1 minute — the dynamic table will re-aggregate automatically
-- within 60 seconds of any new INSERT to CYBER_INCIDENTS_RAW.
--
-- The query groups by date + agency + severity + incident_type + status,
-- producing a compact summary that the Streamlit app can filter and aggregate
-- without touching the full raw table. Snowflake will use incremental refresh
-- for INSERT-only workloads on the base table.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE CYBER_INCIDENTS_SUMMARY
    TARGET_LAG = '1 minute'
    WAREHOUSE  = DEMO_WH
    COMMENT    = 'Aggregated cyber incident summary, refreshed within 60s of raw table changes'
AS
SELECT
    DATE_TRUNC('day', detected_at)::DATE   AS incident_date,
    agency,
    severity,
    incident_type,
    status,
    COUNT(*)                               AS incident_count,
    SUM(affected_systems)                  AS total_affected_systems,
    AVG(affected_systems)                  AS avg_affected_systems,
    MIN(detected_at)                       AS earliest_detection,
    MAX(detected_at)                       AS latest_detection
FROM CYBER_INCIDENTS_RAW
GROUP BY
    DATE_TRUNC('day', detected_at)::DATE,
    agency,
    severity,
    incident_type,
    status;


-- =============================================================================
-- SECTION 7: VERIFICATION QUERIES
-- =============================================================================
-- Run these after the script completes to confirm everything is in place.
-- Expected results are noted in comments.

-- 7a. Row count on raw table (expect 500)
SELECT COUNT(*) AS raw_row_count FROM CYBER_INCIDENTS_RAW;

-- 7b. Severity distribution (expect roughly Critical~10%, High~20%, Med~40%, Low~30%)
SELECT severity, COUNT(*) AS cnt, ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM CYBER_INCIDENTS_RAW
GROUP BY severity
ORDER BY cnt DESC;

-- 7c. Agency distribution (expect CISA and DOD highest)
SELECT agency, COUNT(*) AS cnt
FROM CYBER_INCIDENTS_RAW
GROUP BY agency
ORDER BY cnt DESC;

-- 7d. Confirm dynamic table exists (TARGET_LAG, REFRESH_MODE, SCHEDULING_STATE visible here)
SHOW DYNAMIC TABLES LIKE 'CYBER_INCIDENTS_SUMMARY' IN SCHEMA CYBER_DEMO.PUBLIC;

-- 7d-ii. Row count in the dynamic table (run ~60s after the INSERT so the lag has elapsed)
SELECT COUNT(*) AS summary_row_count FROM CYBER_INCIDENTS_SUMMARY;

-- 7e. Sample summary rows from dynamic table
SELECT * FROM CYBER_INCIDENTS_SUMMARY
ORDER BY incident_date DESC
LIMIT 20;

-- 7f. Quick Cortex smoke test — confirm the role can call COMPLETE
-- (Replace 'llama3.1-70b' with 'claude-3-5-sonnet' if available in your region)
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    'In one sentence, confirm that Snowflake Cortex is working.'
) AS cortex_check;
