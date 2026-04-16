"""
Security management router.
"""
from fastapi import APIRouter, HTTPException
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models import SecurityStatus, SuccessResponse
from services import StatusService, ScriptService

router = APIRouter(prefix="/security", tags=["security"])

status_service = StatusService()
script_service = ScriptService()


@router.get("/status", response_model=SecurityStatus)
async def get_security_status():
    """Get security layer status."""
    try:
        status = status_service.get_security_status()
        return SecurityStatus(**status)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/preflight")
async def run_preflight():
    """Run preflight checks."""
    try:
        status = status_service.get_security_status()
        return {
            "success": True,
            "message": "Preflight check completed",
            "result": status
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/firewall", response_model=SuccessResponse)
async def setup_firewall():
    """Apply firewall rules."""
    try:
        result = script_service.setup_firewall()
        if result['success']:
            return SuccessResponse(message="Firewall rules applied")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/firewall", response_model=SuccessResponse)
async def flush_firewall():
    """Flush firewall rules."""
    try:
        result = script_service.flush_firewall()
        if result['success']:
            return SuccessResponse(message="Firewall rules flushed")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))