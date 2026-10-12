/*
================================================================================
FILE: 04_SQL_Agent_Job_Setup.sql
PROJECT: Automotive Components Manufacturing & Supply Chain Analytics
PURPOSE: SQL Server Agent job that runs the Manufacturing_DW ETL.

PREREQUISITE
------------
02_Manufacturing_DW_Setup.sql and 03_ETL_StoredProcedures.sql must already
have run successfully. SQL Server Agent must be running (verified live on
this machine: "SQL Server Agent (MSSQLSERVER)" service, status Running).

WHERE THIS FITS -- ONE JOB, ONE JOB ONLY
-------------------------------------------
Per the architecture blueprint: SQL Server Agent's only job is orchestrating
the ETL step (stage 3), never anything upstream (Python) or downstream
(Power BI refresh) -- those own their own schedules independently. The
three stages form a dependency chain, not three independent clocks:

    Windows Task Scheduler -> main_incremental_update.py -> (exits 0)
        -> SQL Server Agent job "Manufacturing_DW_Incremental_ETL"
        -> EXEC etl.usp_RunFullETL
        -> Power BI Service scheduled refresh (a few hours later, stage 5)

TRIGGER MECHANISM: sp_start_job, not a fixed time offset
-----------------------------------------------------------
A fixed schedule (e.g. "run nightly at 2 AM") would let a slow or failed
Python run leave the ETL job pulling from a half-written source, or running
against yesterday's data. Instead, the job below is created with NO enabled
schedule -- it is started on demand by whatever just finished the Python
step successfully. Two ways to do that, both wired to the same job:

  1. Manual / interactive: run main_incremental_update.py, then once it
     exits 0, run:
         sqlcmd -S localhost -E -Q "EXEC msdb.dbo.sp_start_job N'Manufacturing_DW_Incremental_ETL';"

  2. Automated: wrap both steps in one Windows Task Scheduler action (or a
     tiny .bat) that only calls sp_start_job if the Python step's exit code
     was 0:
         python main_incremental_update.py
         if %ERRORLEVEL% EQU 0 (
             sqlcmd -S localhost -E -Q "EXEC msdb.dbo.sp_start_job N'Manufacturing_DW_Incremental_ETL';"
         )
     This file does not create that wrapper .bat -- it belongs alongside
     the Python project's existing run_incremental_update.bat, as a
     deliberate choice by whoever wires up the Task Scheduler entry, not
     something this SQL script should reach into another project to create.

A backup DAILY schedule (03:00 AM, disabled by default -- see Step 3) is
also created so the chain still self-heals if a manual trigger is ever
missed, without being the primary trigger.

HINGLISH:
Chautha file -- SQL Server Agent job banate hain jo etl.usp_RunFullETL ko
chalata hai. Trigger mainly sp_start_job se (Python ke success ke baad),
schedule sirf backup ke liye hai, disabled by default.
================================================================================
*/

SET NOCOUNT ON;
GO

USE msdb;
GO


/*==============================================================================
  STEP 1 - JOB CATEGORY (optional, keeps this job easy to find in SSMS)
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = N'Manufacturing Analytics' AND category_class = 1)
BEGIN
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'Manufacturing Analytics';
    PRINT 'Created job category: Manufacturing Analytics';
END;
GO


/*==============================================================================
  STEP 2 - THE JOB
==============================================================================*/

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Manufacturing_DW_Incremental_ETL')
BEGIN
    PRINT 'Job Manufacturing_DW_Incremental_ETL already exists -- dropping and recreating so this script stays idempotent.';
    EXEC msdb.dbo.sp_delete_job @job_name = N'Manufacturing_DW_Incremental_ETL', @delete_unused_schedule = 1;
END;
GO

DECLARE @jobId BINARY(16);

EXEC msdb.dbo.sp_add_job
    @job_name = N'Manufacturing_DW_Incremental_ETL',
    @enabled = 1,
    @description = N'Runs etl.usp_RunFullETL against Manufacturing_DW. Triggered by sp_start_job right after main_incremental_update.py exits 0 -- see the header comment in 04_SQL_Agent_Job_Setup.sql for the full trigger design. The 03:00 AM daily schedule (disabled by default) is a self-healing backup only, not the primary trigger.',
    @category_name = N'Manufacturing Analytics',
    @owner_login_name = N'sa',
    @job_id = @jobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_name = N'Run Manufacturing_DW ETL',
    @step_id = 1,
    @subsystem = N'TSQL',
    @database_name = N'Manufacturing_DW',
    @command = N'EXEC etl.usp_RunFullETL;',
    @retry_attempts = 0,
    @on_success_action = 1,   -- quit with success
    @on_fail_action = 2;      -- quit with failure

EXEC msdb.dbo.sp_add_jobserver
    @job_id = @jobId,
    @server_name = N'(local)';

PRINT 'Created job Manufacturing_DW_Incremental_ETL';
GO


/*==============================================================================
  STEP 3 - BACKUP SCHEDULE (disabled by default -- see header comment)
==============================================================================*/

IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysschedules s
    INNER JOIN msdb.dbo.sysjobschedules js ON js.schedule_id = s.schedule_id
    INNER JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
    WHERE j.name = N'Manufacturing_DW_Incremental_ETL' AND s.name = N'Daily backup 3AM (disabled by default)'
)
BEGIN
    EXEC msdb.dbo.sp_add_jobschedule
        @job_name = N'Manufacturing_DW_Incremental_ETL',
        @name = N'Daily backup 3AM (disabled by default)',
        @enabled = 0,                  -- OFF by default: sp_start_job is the real trigger
        @freq_type = 4,                -- daily
        @freq_interval = 1,
        @active_start_time = 030000;   -- 03:00:00

    PRINT 'Created backup schedule (disabled) on Manufacturing_DW_Incremental_ETL';
END;
GO


/*==============================================================================
  STEP 4 - VALIDATION: run the job once, right now, and confirm it succeeds
==============================================================================*/

PRINT '==============================================================';
PRINT 'Starting Manufacturing_DW_Incremental_ETL now to verify the job runs end to end...';
PRINT '==============================================================';

EXEC msdb.dbo.sp_start_job @job_name = N'Manufacturing_DW_Incremental_ETL';
GO

WAITFOR DELAY '00:00:05';
GO

SELECT TOP 5
    j.name AS JobName,
    h.run_date,
    h.run_time,
    CASE h.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 2 THEN 'Retry' WHEN 3 THEN 'Canceled' WHEN 4 THEN 'In Progress' END AS RunStatus,
    h.run_duration,
    h.message
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = N'Manufacturing_DW_Incremental_ETL'
ORDER BY h.instance_id DESC;
GO


/*==============================================================================
  EXPECTED RESULT AFTER SUCCESS
==============================================================================

msdb.dbo.sysjobs: one job, "Manufacturing_DW_Incremental_ETL", enabled,
category "Manufacturing Analytics", one T-SQL step calling
etl.usp_RunFullETL against Manufacturing_DW.

msdb.dbo.sysjobschedules: one schedule attached, "Daily backup 3AM
(disabled by default)", disabled.

msdb.dbo.sysjobhistory: at least one row for this job with RunStatus =
Succeeded (from the Step 4 validation run above). If it shows Failed,
check etl.BatchRun / etl.BatchAudit / etl.RejectedRows in Manufacturing_DW
for the actual error -- the job step's message column will point there too.

DAY-TO-DAY USAGE
-----------------
    python main_incremental_update.py
    sqlcmd -S localhost -E -Q "EXEC msdb.dbo.sp_start_job N'Manufacturing_DW_Incremental_ETL';"

STAGE 3 IS NOW COMPLETE
-------------------------
Manufacturing_DW (raw/stg/mart/etl), the 36 ETL procedures, and this Agent
job are all live and verified. Stage 4 (Power BI semantic model, Import
mode, connecting only to Manufacturing_DW.mart) is next -- see the
architecture blueprint.
================================================================================
*/
