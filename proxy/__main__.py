import os

import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "proxy.server:app",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", 4000)),
    )
