"""
Cleanup operations router.
"""
from fastapi import APIRouter, HTTPException
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models import CleanupConfirm, SuccessResponse
from services import ScriptService

router = APIRouter(prefix="/cleanup", tags=["cleanup"])

script_service = ScriptService()


@router.post("/clean", response_model=SuccessResponse)
async def clean_runtime():
    """Clean runtime files (tmp data, htpasswd)."""
    try:
        result = script_service.clean_runtime()
        if result['success']:
            return SuccessResponse(message="Runtime files cleaned")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/purge-data", response_model=SuccessResponse)
async def purge_data(confirm: CleanupConfirm):
    """Purge agent data directories (requires confirmation)."""
    if confirm.confirm != "yes":
        raise HTTPException(status_code=400, detail="Confirmation required: type 'yes'")
    
    try:
        result = script_service.purge_data()
        if result['success']:
            return SuccessResponse(message="Agent data directories removed")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/uninstall", response_model=SuccessResponse)
async def uninstall(confirm: CleanupConfirm):
    """Run uninstall script (requires confirmation)."""
    if confirm.confirm != "yes":
        raise HTTPException(status_code=400, detail="Confirmation required: type 'yes'")
    
    try:
        result = script_service.uninstall()
        if result['success']:
            return SuccessResponse(message="Uninstall completed")
        else:
            raise HTTPException(status_code=500, detail=result['stderr'])
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/purge", response_model=SuccessResponse)
async def full_purge(confirm: CleanupConfirm):
    """Full purge: uninstall + remove config and data (requires confirmation)."""
    if confirm.confirm != "yes":
        raise HTTPException(status_code=400, detail="Confirmation required: type 'yes'")
    
    try:
        # Run uninstall
        uninstall_result = script_service.uninstall()
        if not uninstall_result['success']:
            raise HTTPException(status_code=500, detail=f"Uninstall failed: {uninstall_result['stderr']}")
        
        # Remove config files
        import subprocess
        subprocess.run(['rm', '-f', '/app/config/.env', '/app/config/config.json'], check=False)
        
        # Remove data directories
        purge_result = script_service.purge_data()
        
        return SuccessResponse(message="Full purge completed")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))