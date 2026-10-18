from fastapi import Request
from fastapi.routing import APIRoute
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.config import get_settings


class Base(DeclarativeBase):
    pass


engine = create_async_engine(get_settings().database_url, pool_pre_ping=True)
Session = async_sessionmaker(engine, expire_on_commit=False)


class TransactionRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def transactional(request: Request):
            response = await handler(request)
            db = getattr(request.state, "db", None)
            if db is not None:
                # FastAPI 0.118 finalizes yield dependencies after sending the response.
                # Commit here so a failed transaction cannot be reported as success.
                await db.commit()
            return response

        return transactional


async def get_db(request: Request):
    async with Session() as db:
        request.state.db = db
        try:
            yield db
        except Exception:
            await db.rollback()
            raise
