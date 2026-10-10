import asyncio
import html
import os
import sqlite3
from datetime import datetime

from aiogram import Bot, Dispatcher, F, Router
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.exceptions import TelegramBadRequest
from aiogram.filters import CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import CallbackQuery, FSInputFile, InlineKeyboardButton, Message
from aiogram.utils.keyboard import InlineKeyboardBuilder

TOKEN = ("8650943641:AAF00v3vMrfEXoJMcE6S3fnvRJ1wAmZlzA4")  # токен от @BotFather
MENU_IMAGE = "menu.jpg"  # картинка меню лежит рядом с bot.py

DAYS = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

# Обычные эмодзи: показываются, если ID премиум-эмодзи не задан.
PLAIN_EMOJI = {
    "add": "➕",
    "list": "📅",
    "profile": "👤",
    "back": "⬅️",
}

# ID премиум-эмодзи для кнопок. Пустая строка = использовать обычное эмодзи.
# Получить ID: отправьте боту сообщение с премиум-эмодзи, он ответит их ID.
CUSTOM_EMOJI_IDS = {
    "add": "5204334545419124784",
    "list": "5204334545419124784",
    "profile": "5204334545419124784",
    "back": "5204334545419124784",
}

db = sqlite3.connect("schedule.db")
db.execute(
    """CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        day INTEGER NOT NULL,
        time TEXT NOT NULL,
        title TEXT NOT NULL
    )"""
)
db.commit()

router = Router()


class AddItem(StatesGroup):
    day = State()
    time = State()
    title = State()


def btn(key: str, text: str, callback: str, style: str | None = None) -> InlineKeyboardButton:
    """Кнопка с премиум-эмодзи (если задан ID) или с обычным эмодзи.

    style: "primary" (синяя), "success" (зелёная), "danger" (красная) или None.
    """
    icon = CUSTOM_EMOJI_IDS.get(key) or None
    return InlineKeyboardButton(
        text=text if icon else f"{PLAIN_EMOJI[key]} {text}",
        callback_data=callback,
        icon_custom_emoji_id=icon,
        style=style,
    )


def main_menu():
    kb = InlineKeyboardBuilder()
    kb.row(btn("add", "Добавить расписание", "add", style="success"))
    kb.row(btn("list", "Моё расписание", "list"), btn("profile", "Профиль", "profile"))
    return kb.as_markup()


def back_menu():
    kb = InlineKeyboardBuilder()
    kb.row(btn("back", "В меню", "menu"))
    return kb.as_markup()


def days_menu():
    kb = InlineKeyboardBuilder()
    for i, name in enumerate(DAYS):
        kb.button(text=name, callback_data=f"day:{i}")
    kb.adjust(4, 3)
    kb.row(btn("back", "В меню", "menu"))
    return kb.as_markup()


MENU_TEXT = "<b>Главное меню</b>\nВыберите действие:"


async def send_menu(message: Message):
    if os.path.exists(MENU_IMAGE):
        await message.answer_photo(FSInputFile(MENU_IMAGE), caption=MENU_TEXT, reply_markup=main_menu())
    else:
        await message.answer(MENU_TEXT, reply_markup=main_menu())


async def show(call: CallbackQuery, text: str, markup):
    """Редактирует текущее сообщение (и с картинкой, и без)."""
    try:
        if call.message.photo:
            await call.message.edit_caption(caption=text, reply_markup=markup)
        else:
            await call.message.edit_text(text, reply_markup=markup)
    except TelegramBadRequest:
        pass
    await call.answer()


@router.message(CommandStart())
async def start(message: Message, state: FSMContext):
    await state.clear()
    await send_menu(message)


@router.callback_query(F.data == "menu")
async def menu(call: CallbackQuery, state: FSMContext):
    await state.clear()
    await show(call, MENU_TEXT, main_menu())


# ---------- Добавление расписания ----------

@router.callback_query(F.data == "add")
async def add_start(call: CallbackQuery, state: FSMContext):
    await state.set_state(AddItem.day)
    await show(call, "<b>Добавить расписание</b>\nВыберите день недели:", days_menu())


@router.callback_query(AddItem.day, F.data.startswith("day:"))
async def add_day(call: CallbackQuery, state: FSMContext):
    await state.update_data(day=int(call.data.split(":")[1]))
    await state.set_state(AddItem.time)
    await show(call, "Введите время в формате <b>ЧЧ:ММ</b>, например <code>09:30</code>", back_menu())


@router.message(AddItem.time, F.text)
async def add_time(message: Message, state: FSMContext):
    try:
        t = datetime.strptime(message.text.strip(), "%H:%M").strftime("%H:%M")
    except ValueError:
        await message.answer("Не похоже на время. Формат: <b>ЧЧ:ММ</b>, например <code>09:30</code>")
        return
    await state.update_data(time=t)
    await state.set_state(AddItem.title)
    await message.answer("Теперь введите название (предмет, смена, дело):")


@router.message(AddItem.title, F.text)
async def add_title(message: Message, state: FSMContext):
    data = await state.get_data()
    db.execute(
        "INSERT INTO items (user_id, day, time, title) VALUES (?, ?, ?, ?)",
        (message.from_user.id, data["day"], data["time"], message.text.strip()),
    )
    db.commit()
    await state.clear()
    await message.answer(f"✅ Добавлено: <b>{DAYS[data['day']]}</b>, {data['time']}")
    await send_menu(message)


# ---------- Просмотр и профиль ----------

@router.callback_query(F.data == "list")
async def show_list(call: CallbackQuery):
    rows = db.execute(
        "SELECT day, time, title FROM items WHERE user_id = ? ORDER BY day, time",
        (call.from_user.id,),
    ).fetchall()
    if not rows:
        text = "<b>Моё расписание</b>\nПока пусто. Нажмите «Добавить расписание»."
    else:
        lines = ["<b>Моё расписание</b>"]
        current = None
        for day, time, title in rows:
            if day != current:
                lines.append(f"\n<b>{DAYS[day]}</b>")
                current = day
            lines.append(f"{time} — {html.escape(title)}")
        text = "\n".join(lines)
    await show(call, text, back_menu())


@router.callback_query(F.data == "profile")
async def profile(call: CallbackQuery):
    count = db.execute(
        "SELECT COUNT(*) FROM items WHERE user_id = ?", (call.from_user.id,)
    ).fetchone()[0]
    text = (
        "<b>Профиль</b>\n"
        f"Имя: {html.escape(call.from_user.full_name)}\n"
        f"ID: <code>{call.from_user.id}</code>\n"
        f"Записей в расписании: <b>{count}</b>"
    )
    await show(call, text, back_menu())


# ---------- Помощник: узнать ID премиум-эмодзи ----------

def has_custom_emoji(message: Message) -> bool:
    return any(e.type == "custom_emoji" for e in (message.entities or []))


@router.message(has_custom_emoji)
async def emoji_ids(message: Message):
    ids = [e.custom_emoji_id for e in message.entities if e.type == "custom_emoji"]
    await message.answer("ID премиум-эмодзи:\n" + "\n".join(f"<code>{i}</code>" for i in ids))


async def main():
    if not TOKEN:
        raise SystemExit("Задайте токен: export BOT_TOKEN=...")
    bot = Bot(TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
